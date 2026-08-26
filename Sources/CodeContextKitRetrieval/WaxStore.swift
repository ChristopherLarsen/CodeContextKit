import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import Wax

/// Actor-based WaxStore that provides semantic search and relationship mapping.
///
/// Opens Wax `Memory` with the built-in MiniLM embedder so semantic search uses
/// real vector retrieval. Without MiniLM, Wax silently disables vectors and
/// natural-language queries return empty — we refuse that silent degradation.
public actor WaxStore {
    private let path: String
    private var memory: Memory?
    /// True only when Memory was opened with MiniLM (vector search enabled).
    private var embeddingsEnabled: Bool = false

    public init(path: String) async throws {
        self.path = path
        await openMemory()
    }

    /// Wipe the `.wax` file and reopen. Used when SQLite has files but no tracked
    /// frame IDs — surgical delete is impossible, so the vector store must be rebuilt.
    public func resetStore() async throws {
        try await memory?.close()
        memory = nil
        embeddingsEnabled = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: url)
        }
        await openMemory()
    }
    
    public func countTokens(_ text: String) async -> Int {
        return TokenEstimator.shared.estimate(text)
    }
    
    /// Ingest a symbol and return the Wax frame IDs (and mandate) so the indexer
    /// can delete them on re-index. `Memory.save` returns the document and chunk IDs.
    @discardableResult
    public func saveSymbol(_ symbol: SymbolRecord, body: String) async throws -> WaxSymbolIngest {
        guard let memory = memory else { return .skipped }
        guard SemanticIndexPolicy.shouldIndex(symbol, body: body) else { return .skipped }

        let text = SemanticIndexPolicy.documentText(for: symbol, body: body)
        let hash = Self.fnv1a64(text)
        let mandate = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = Self.mandateToken(mandate)
        let stored = text + "\n" + token

        let metadata = [
            "qualifiedName": symbol.qualifiedName,
            "filePath": symbol.filePath,
            "kind": "\(symbol.kind)",
            "contentHash": String(hash),
            "mandate": mandate
        ]
        let savedIDs = try await memory.save(stored, metadata: metadata)
        let frameIDs = savedIDs.isEmpty ? try await framesMatching(mandate: mandate) : savedIDs
        return WaxSymbolIngest(mandate: mandate, frameIDs: frameIDs)
    }

    public func deleteFrames(_ frameIDs: [UInt64]) async throws {
        guard let memory, !frameIDs.isEmpty else { return }
        var seen = Set<UInt64>()
        for id in frameIDs where seen.insert(id).inserted {
            do {
                try await memory.delete(frameID: id)
            } catch {
                // Already deleted / unknown id after a partial rebuild.
            }
        }
    }

    /// Retract frames whose mandate token is still searchable (covers chunk frames
    /// whose IDs were never persisted on older indexes).
    public func deleteByMandates(_ mandates: [String]) async throws {
        guard memory != nil, !mandates.isEmpty else { return }
        var ids: [UInt64] = []
        for mandate in mandates where !mandate.isEmpty {
            ids.append(contentsOf: try await framesMatching(mandate: mandate))
        }
        try await deleteFrames(ids)
    }

    public static func symbolKey(filePath: String, qualifiedName: String) -> String {
        "\(filePath)\u{1f}\(qualifiedName)"
    }

    /// Drop vectors that are not in the current SQLite keep-set. Does not re-embed.
    ///
    /// Prefer recorded frame IDs from SQLite. For a live symbol with no recorded IDs
    /// (legacy leak), keep the newest ingest and delete older duplicates.
    public func compact(
        recordedFrameIDs: Set<UInt64>,
        liveSymbolKeys: Set<String>
    ) async throws -> WaxCompactResult {
        guard let memory else {
            return WaxCompactResult(scanned: 0, deleted: 0, kept: 0)
        }
        try await memory.flush()
        let bytesBefore = waxFileBytes()
        let frames = await memory.activeFrames()
        var keep = Set<UInt64>()

        var byKey: [String: [Memory.FrameSummary]] = [:]
        var untagged: [Memory.FrameSummary] = []
        for frame in frames {
            if let path = frame.metadata["filePath"], !path.isEmpty,
               let name = frame.metadata["qualifiedName"], !name.isEmpty {
                byKey[Self.symbolKey(filePath: path, qualifiedName: name), default: []].append(frame)
            } else {
                untagged.append(frame)
            }
        }

        for (symbolKey, group) in byKey {
            guard liveSymbolKeys.contains(symbolKey) else { continue }
            let recordedInGroup = group.filter { recordedFrameIDs.contains($0.id) }
            if !recordedInGroup.isEmpty {
                keep.formUnion(recordedInGroup.map(\.id))
                continue
            }
            guard let newest = group.max(by: { $0.timestampMs < $1.timestampMs }) else { continue }
            let parent = newest.parentId ?? newest.id
            keep.insert(parent)
            for frame in group where frame.id == parent || frame.parentId == parent {
                keep.insert(frame.id)
            }
        }

        for frame in untagged {
            if let parent = frame.parentId {
                if keep.contains(parent) {
                    keep.insert(frame.id)
                }
            } else {
                keep.insert(frame.id)
            }
        }

        var changed = true
        while changed {
            changed = false
            for frame in frames where !keep.contains(frame.id) {
                if let parent = frame.parentId, keep.contains(parent) {
                    keep.insert(frame.id)
                    changed = true
                }
            }
        }

        var deleted = 0
        for frame in frames where !keep.contains(frame.id) {
            do {
                try await memory.delete(frameID: frame.id)
                deleted += 1
            } catch {
                // Already deleted / unknown id after a partial rebuild.
            }
        }
        try await memory.flush()

        // Soft deletes never shrink repo.wax by themselves. The file bytes are
        // reclaimed when this store is CLOSED: Wax's close-time live-set rewrite
        // drops non-live payloads, preserves frame IDs, carries committed vector
        // bytes over (no re-embed), and promotes the compacted candidate over the
        // source file. Callers therefore measure the post-close size (and stamp
        // compaction results) only after `close()` — see IndexCommand.

        return WaxCompactResult(
            scanned: frames.count,
            deleted: deleted,
            kept: frames.count - deleted,
            bytesBefore: bytesBefore
        )
    }
    
    public func search(_ query: String, limit: Int = 10) async throws -> [SearchResult] {
        try requireEmbeddings()
        guard let memory = memory else { return [] }

        // Ask Wax for a wider candidate pool than we return so FastRAG/ANN
        // ranking can surface needles before snippet assembly truncates.
        // Identifier-shaped queries are routed to SQLite in SearchCommand — Wax
        // only sees natural-language meaning queries (vector-only).
        let candidateK = max(limit, 64)

        let results = try await memory.search(query) { options in
            options.topK = candidateK
            options.mode = .vectorOnly
        }

        return results.items.prefix(limit).map { res in
            let preview = Self.stripMandate(res.text)
            return SearchResult(
                symbol: res.metadata["qualifiedName"] ?? "Unknown",
                file: res.metadata["filePath"] ?? "Unknown",
                kind: res.metadata["kind"] ?? "unknown",
                score: Float(res.score),
                preview: preview,
                estimatedTokens: TokenEstimator.shared.estimate(preview)
            )
        }
    }

    public func getSemanticLinks(for items: [String: String], threshold: Float = 0.3) async -> SemanticResponse {
        var links: [SemanticLink] = []
        let ids = Array(items.keys)
        var vectors: [String: [Float]] = [:]
        var categories: [String: String] = [:] // id -> Topic
        
        for (id, text) in items {
            vectors[id] = generateProxyVector(for: text)
            categories[id] = extractMainTopic(from: text)
        }
        
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let id1 = ids[i]
                let id2 = ids[j]
                guard let v1 = vectors[id1], let v2 = vectors[id2] else { continue }
                
                let score = cosineSimilarity(v1, v2)
                if score >= threshold {
                    links.append(SemanticLink(source: id1, target: id2, strength: score))
                }
            }
        }
        return SemanticResponse(links: links, topics: categories)
    }

    private func extractMainTopic(from text: String) -> String {
        let stopWords: Set<String> = ["the", "and", "func", "struct", "class", "var", "let", "return", "if", "else", "for", "in", "import", "public", "private", "extension", "case", "enum"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopWords.contains($0) }
        
        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.first?.key ?? "General"
    }

    public func estimateComplexity(for text: String) async -> Double {
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let uniqueWords = Set(words).count
        let density = Double(uniqueWords) / max(1.0, Double(words.count))
        let score = (density * 10.0) + (Double(text.count) / 5000.0)
        return score
    }
    
    public func flush() async throws { try await memory?.flush() }
    public func close() async throws { try await memory?.close() }

    /// True when the underlying Wax Memory handle opened successfully.
    public func isAvailable() -> Bool { memory != nil }

    /// True when MiniLM embeddings are active (required for semantic search).
    public func hasEmbeddings() -> Bool { embeddingsEnabled }

    /// Throws unless MiniLM-backed Memory is ready for vector search.
    public func requireEmbeddings() throws {
        guard memory != nil, embeddingsEnabled else {
            throw WaxEmbedderIdentity.ReadinessError.embeddingsUnavailable
        }
    }

    private func openMemory() async {
        let url = URL(fileURLWithPath: path)
        var config = Memory.Config.default
        config.liveSetRewrite = Self.reclaimSettingsFromEnvironment()
        do {
            self.memory = try await Memory(at: url, config: config, builtInEmbedding: .miniLM)
            self.embeddingsEnabled = true
        } catch {
            // Last-resort text-only open so non-semantic flows (token count) can
            // still work; semantic search will refuse via `requireEmbeddings()`.
            do {
                self.memory = try await Memory(at: url, config: config)
                self.embeddingsEnabled = false
            } catch {
                self.memory = nil
                self.embeddingsEnabled = false
            }
        }
    }

    /// Live-set reclamation knobs, overridable per run:
    /// - `CCKIT_WAX_RECLAIM=off` disables reclaim entirely
    /// - `CCKIT_WAX_RECLAIM_FRACTION` dead-bytes fraction (default 0.25)
    /// - `CCKIT_WAX_RECLAIM_MIN_BYTES` absolute floor (default 32 MiB)
    /// - `CCKIT_WAX_RECLAIM_MIN_INTERVAL_MS` cooldown (default 60000)
    ///
    /// Defaults are aggressive (vs Wax's conservative preset) because code-index
    /// stores accumulate stale index segments on every commit; conservative
    /// thresholds only engaged around the ~500 GiB incident.
    static func reclaimSettingsFromEnvironment() -> LiveSetRewriteSettings {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["CCKIT_WAX_RECLAIM"], mode.trimmingCharacters(in: .whitespaces).lowercased() == "off" {
            return LiveSetRewriteSettings(enabled: false)
        }
        func number(_ key: String) -> Double? {
            env[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        var settings = LiveSetRewriteSettings.aggressive
        if let fraction = number("CCKIT_WAX_RECLAIM_FRACTION"), fraction >= 0, fraction <= 1 {
            settings.minDeadPayloadFraction = fraction
        }
        if let minBytes = number("CCKIT_WAX_RECLAIM_MIN_BYTES"), minBytes >= 0 {
            settings.minDeadPayloadBytes = UInt64(minBytes)
        }
        if let intervalMs = number("CCKIT_WAX_RECLAIM_MIN_INTERVAL_MS"), intervalMs >= 0 {
            settings.minIntervalMs = Int(intervalMs)
        }
        if let idleMs = number("CCKIT_WAX_RECLAIM_IDLE_MS"), idleMs >= 0 {
            settings.minimumIdleMs = Int(idleMs)
        }
        return settings
    }

    /// Byte-level accounting of the underlying store (live/dead payloads,
    /// stale index segments). Nil when no store is open.
    public func storeDiagnostics() async throws -> StoreDiagnostics? {
        guard let memory else { return nil }
        return try await memory.storeDiagnostics()
    }

    /// Force one live-set reclamation now (dead payloads + stale index
    /// segments). Nil when no store is open.
    public func runLiveSetReclaimNow() async throws -> LiveSetMaintenanceSummary? {
        guard let memory else { return nil }
        return try await memory.runLiveSetMaintenanceNow()
    }

    /// Bytes actually materialized on disk (st_blocks). Wax preallocates its
    /// arena sparsely, so apparent size overstates by ~2x and drifts further
    /// with use — growth detection and watermarks must use allocated bytes.
    /// Mirrors IndexCommand.waxFileAllocatedBytes(at:); this module cannot see
    /// the CLI target. Internal so WaxCompactStamp.writeBaseline shares it.
    static func waxFileAllocatedBytes(at path: String) -> Int {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]) else { return 0 }
        let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        return max(0, allocated)
    }

    private func waxFileBytes() -> Int {
        Self.waxFileAllocatedBytes(at: path)
    }

    private func framesMatching(mandate: String) async throws -> [UInt64] {
        guard let memory, !mandate.isEmpty else { return [] }
        let token = Self.mandateToken(mandate)
        let results = try await memory.search(token) { options in
            options.topK = 64
            options.mode = .textOnly
        }
        var seen = Set<UInt64>()
        var ids: [UInt64] = []
        for item in results.items {
            let matches = item.metadata["mandate"] == mandate || item.text.contains(token)
            guard matches, seen.insert(item.frameId).inserted else { continue }
            ids.append(item.frameId)
        }
        return ids
    }

    private static func mandateToken(_ mandate: String) -> String {
        "cckitwax_\(mandate)"
    }

    private static func stripMandate(_ text: String) -> String {
        guard let range = text.range(of: "\ncckitwax_", options: .backwards) else {
            return text
        }
        return String(text[..<range.lowerBound])
    }

    private static func fnv1a64(_ string: String) -> UInt64 {
        let prime: UInt64 = 1099511628211
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    // Internal Math for Graph forces
    private func generateProxyVector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0.0, count: 128)
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        for word in words {
            let hash = abs(word.hashValue)
            vector[hash % 128] += 1.0
        }
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if magnitude > 0 { for i in 0..<128 { vector[i] /= magnitude } }
        return vector
    }

    private func cosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count else { return 0 }
        var dotProduct: Float = 0
        for i in 0..<v1.count { dotProduct += v1[i] * v2[i] }
        return dotProduct
    }
}

/// Result of ingesting one symbol into Wax. `frameIDs` come from `Memory.save`;
/// `mandate` still allows delete-by-mandate on older indexes.
public struct WaxSymbolIngest: Sendable, Equatable {
    public let mandate: String
    public let frameIDs: [UInt64]

    public static let skipped = WaxSymbolIngest(mandate: "", frameIDs: [])

    public var didWrite: Bool { !mandate.isEmpty }
}

public struct WaxCompactResult: Sendable, Equatable {
    public let scanned: Int
    public let deleted: Int
    public let kept: Int
    /// repo.wax size in bytes measured before logical deletion. Compare against
    /// the on-disk size measured AFTER `WaxStore.close()` to detect real byte
    /// reclaim (the close-time live-set rewrite is what shrinks the file).
    public let bytesBefore: Int
    /// Size observed after compaction completed. `compact` itself does not
    /// reclaim bytes (that happens on close), so this mirrors `bytesBefore`
    /// unless the caller updates it with a post-close measurement.
    public let bytesAfter: Int

    /// True when the recorded sizes show an actual file shrink.
    public var shrank: Bool { bytesAfter < bytesBefore }

    public init(
        scanned: Int,
        deleted: Int,
        kept: Int,
        bytesBefore: Int = 0,
        bytesAfter: Int = 0
    ) {
        self.scanned = scanned
        self.deleted = deleted
        self.kept = kept
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
    }
}

public struct SemanticResponse: Codable, Sendable {
    public let links: [SemanticLink]
    public let topics: [String: String]
}

public struct SemanticLink: Codable, Sendable {
    public let source: String
    public let target: String
    public let strength: Float
}

public struct SearchResult: Codable, Sendable {
    public let symbol: String
    public let file: String
    public let kind: String
    public let score: Float
    public let preview: String
    public let estimatedTokens: Int
    
    public init(symbol: String, file: String, kind: String, score: Float, preview: String, estimatedTokens: Int) {
        self.symbol = symbol; self.file = file; self.kind = kind; self.score = score; self.preview = preview; self.estimatedTokens = estimatedTokens
    }
}

/// Tracks which on-device embedder built `.cckit/repo.wax`.
///
/// Semantic search requires MiniLM vectors. Older indexes (text-only) and upgrades
/// must rebuild via `cckit index` before `semantic:` / pack / serve work.
public enum WaxEmbedderIdentity {
    /// Bump when the embedding model/dimensions change so indexes are rebuilt.
    public static let current = "Wax.BuiltIn.miniLM.v2-selective"
    public static let sidecarFileName = "wax-embedder-id"

    public enum ReadinessError: Error, LocalizedError, Equatable {
        case missingIndex
        case outdated(stored: String?)
        case embeddingsUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingIndex:
                return "Index not found. Run 'cckit index .' first."
            case .outdated(let stored):
                let from = stored ?? "none"
                return "Semantic vector index is outdated (\(from) → \(current)). Run 'cckit index .' to rebuild."
            case .embeddingsUnavailable:
                return "Semantic embeddings unavailable (MiniLM failed to load). Check Wax resource bundles and re-run 'cckit index .'."
            }
        }
    }

    /// Stored embedder id next to the wax file, if any.
    public static func storedId(cckitDir: String = ".cckit") -> String? {
        let path = (cckitDir as NSString).appendingPathComponent(sidecarFileName)
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Whether the on-disk index matches the embedder this build expects.
    public static func isCurrent(cckitDir: String = ".cckit") -> Bool {
        storedId(cckitDir: cckitDir) == current
    }

    /// Throws unless `.cckit` has a vector index built with the current embedder.
    public static func requireCurrent(cckitDir: String = ".cckit") throws {
        let fm = FileManager.default
        let waxPath = (cckitDir as NSString).appendingPathComponent("repo.wax")
        let dbPath = (cckitDir as NSString).appendingPathComponent("index.sqlite")
        guard fm.fileExists(atPath: waxPath), fm.fileExists(atPath: dbPath) else {
            throw ReadinessError.missingIndex
        }
        let stored = storedId(cckitDir: cckitDir)
        guard stored == current else {
            throw ReadinessError.outdated(stored: stored)
        }
    }

    public static func writeSidecar(cckitDir: String = ".cckit") throws {
        let path = (cckitDir as NSString).appendingPathComponent(sidecarFileName)
        try current.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Records `repo.wax` size after a compact that actually reclaimed file bytes,
/// so MCP can treat "healthy at this watermark" as skip-compaction.
///
/// Stamping an arbitrary post-compaction `st_size` would latch bloat as the
/// healthy baseline and hide future growth, so the stamp is written only when
/// the compaction deleted frames AND the file shrank. Freshly rebuilt stores
/// use ``writeBaseline(cckitDir:)`` instead.
public enum WaxCompactStamp {
    public static let fileName = "wax-compact-stamp.json"

    /// Stamp the post-compaction size, but only for a real reclamation:
    /// `deleted > 0` and the file actually shrank. Returns whether it stamped.
    @discardableResult
    public static func writeIfReclaimed(
        cckitDir: String = ".cckit",
        deleted: Int,
        bytesBefore: Int,
        bytesAfter: Int
    ) throws -> Bool {
        guard deleted > 0, bytesAfter < bytesBefore else { return false }
        try write(cckitDir: cckitDir, waxBytes: bytesAfter, deletedFrames: deleted)
        return true
    }

    /// Baseline stamp for a freshly rebuilt store (no leaked payloads yet), so
    /// MCP does not compact a brand-new index. Records allocated bytes: this
    /// watermark gates compaction, and an apparent-size stamp reintroduces the
    /// latched-watermark failure shape on the next --clean.
    public static func writeBaseline(cckitDir: String = ".cckit") throws {
        let waxPath = (cckitDir as NSString).appendingPathComponent("repo.wax")
        let waxBytes = WaxStore.waxFileAllocatedBytes(at: waxPath)
        try write(cckitDir: cckitDir, waxBytes: waxBytes, deletedFrames: 0)
    }

    private static func write(cckitDir: String, waxBytes: Int, deletedFrames: Int) throws {
        let payload: [String: Any] = [
            "waxBytes": waxBytes,
            "deletedFrames": deletedFrames,
            "compactedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let path = (cckitDir as NSString).appendingPathComponent(fileName)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Circuit breaker for arena bloat.
///
/// Compares `repo.wax`'s on-disk size against the bytes the same logical
/// content should occupy (live frame payloads + current lex/vec index blobs).
/// A store several multiples past that is carrying garbage no frame-level
/// compaction can report — historically by orphaned index segments appended
/// per commit.
public enum WaxBloatGuard {
    public static let defaultFactor = 10.0

    /// True when `fileBytes` exceeds `factor × expectedLiveBytes`.
    ///
    /// Guards against false positives on tiny/young stores and when the live
    /// estimate is unusable (zero).
    public static func isBreached(
        fileBytes: UInt64,
        expectedLiveBytes: UInt64,
        factor: Double
    ) -> Bool {
        guard factor > 0 else { return false }
        guard fileBytes > 0, expectedLiveBytes > 0 else { return false }
        return Double(fileBytes) > Double(expectedLiveBytes) * factor
    }

    /// Breaker multiplier from `CCKIT_WAX_BREAKER_FACTOR`; `<= 0` disables.
    public static func factorFromEnvironment() -> Double {
        guard let raw = ProcessInfo.processInfo.environment["CCKIT_WAX_BREAKER_FACTOR"],
              let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            return defaultFactor
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
