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
    public enum StoreError: LocalizedError {
        case inUse(lockPath: String)
        case ambiguousPromotionRecovery(path: String, backups: [String])

        public var errorDescription: String? {
            switch self {
            case .inUse(let lockPath):
                return "Wax store is already in use (stable lease: \(lockPath)). Stop the other cckit process and retry."
            case .ambiguousPromotionRecovery(let path, let backups):
                return "Wax arena is missing at \(path), but multiple promotion backups exist: \(backups.joined(separator: ", ")). Refusing to guess which one is authoritative."
            }
        }
    }

    private let path: String
    private let lease: RefreshLock.Lease
    private var memory: Memory?
    /// True only when Memory was opened with MiniLM (vector search enabled).
    private var embeddingsEnabled: Bool = false
    /// Why the last open attempt degraded or failed (embeddings or store).
    /// Previously both open failures were swallowed, so every consumer saw a
    /// generic "MiniLM failed to load" while the real cause — an unopenable
    /// arena, a permissions error, a missing bundle — stayed invisible.
    public private(set) var lastOpenError: String?

    public init(path: String) async throws {
        let lease = try Self.acquireLease(for: path)
        self.path = path
        self.lease = lease
        try Self.recoverSolePromotionBackupIfNeeded(at: path)
        await openMemory()
    }

    /// Open with a lease acquired before a caller mutates the arena path.
    /// IndexCommand uses this to make clean/rebuild deletion race-free.
    public init(path: String, lease: RefreshLock.Lease) async throws {
        self.path = path
        self.lease = lease
        try Self.recoverSolePromotionBackupIfNeeded(at: path)
        await openMemory()
    }

    /// Acquire the stable cckit ownership lock for an arena without waiting.
    /// The sidecar inode is never replaced with the Wax arena, so it remains a
    /// valid exclusion point across delete/recreate and upstream promotion.
    public nonisolated static func acquireLease(for path: String) throws -> RefreshLock.Lease {
        let lockPath = path + ".lock"
        let parent = (lockPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        guard let lease = RefreshLock.tryAcquire(lockPath: lockPath) else {
            throw StoreError.inUse(lockPath: lockPath)
        }
        return lease
    }

    /// If upstream promotion was interrupted after moving the source aside,
    /// restore the only unambiguous backup before Wax can create an empty arena.
    static func recoverSolePromotionBackupIfNeeded(at path: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }

        let arenaURL = URL(fileURLWithPath: path)
        let directory = arenaURL.deletingLastPathComponent()
        let prefix = arenaURL.lastPathComponent + ".pre-liveset-"
        let candidates = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.lastPathComponent.hasPrefix(prefix) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !candidates.isEmpty else { return }
        guard candidates.count == 1, let backup = candidates.first else {
            throw StoreError.ambiguousPromotionRecovery(
                path: path,
                backups: candidates.map(\.lastPathComponent)
            )
        }
        try fm.moveItem(at: backup, to: arenaURL)
    }

    /// Wipe the `.wax` file and reopen. Current Wax has no public batch-delete
    /// transaction, so cckit replaces this derived store on semantic changes.
    public func resetStore() async throws {
        try await memory?.close()
        memory = nil
        embeddingsEnabled = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: url)
        }
        _ = WaxResidueSweeper.sweep(cckitDirectory: url.deletingLastPathComponent().path)
        await openMemory()
    }
    
    public func countTokens(_ text: String) async -> Int {
        return TokenEstimator.shared.estimate(text)
    }
    
    /// Ingest a symbol and return its cckit mandate for SQLite bookkeeping.
    ///
    /// Current Wax intentionally does not return frame IDs from `Memory.save`.
    /// cckit therefore treats the Wax arena as a replaceable derived artifact and
    /// rebuilds it when semantic inputs change instead of issuing per-frame deletes.
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
        try await memory.save(stored, metadata: metadata)
        return WaxSymbolIngest(mandate: mandate, frameIDs: [])
    }

    public static func symbolKey(filePath: String, qualifiedName: String) -> String {
        "\(filePath)\u{1f}\(qualifiedName)"
    }

    /// Public Wax health counters that remain available across upstream releases.
    public func frameCount() async -> Int {
        guard let memory else { return 0 }
        return Int((await memory.stats()).frameCount)
    }
    
    public func search(_ query: String, limit: Int = 10) async throws -> [SearchResult] {
        try requireEmbeddings()
        guard let memory = memory else { return [] }

        // Ask Wax for a wider candidate pool than we return so FastRAG/ANN
        // ranking can surface needles before snippet assembly truncates.
        // Identifier-shaped queries are routed to SQLite in SearchCommand — Wax
        // only sees natural-language meaning queries (vector-only).
        let candidateK = max(limit, 64)

        let options = Memory.SearchOptions(topK: candidateK, mode: .vectorOnly)
        let results = try await memory.search(query, options: options)

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
    public func close() async throws {
        defer { lease.release() }
        try await memory?.close()
    }

    /// True when the underlying Wax Memory handle opened successfully.
    public func isAvailable() -> Bool { memory != nil }

    /// True when MiniLM embeddings are active (required for semantic search).
    public func hasEmbeddings() -> Bool { embeddingsEnabled }

    /// Throws unless MiniLM-backed Memory is ready for vector search. The
    /// error carries the real cause: the retained open error, the breach
    /// marker's own numbers when the arena is over its ceiling, and the
    /// bundle hint only when the bundle is genuinely absent.
    public func requireEmbeddings() throws {
        guard memory != nil, embeddingsEnabled else {
            throw WaxEmbedderIdentity.ReadinessError.embeddingsUnavailable(detail: unavailabilityDetail())
        }
    }

    /// Human-readable reason embeddings are off, for operators. Combines the
    /// retained open error with the breach-marker contract when present.
    private func unavailabilityDetail() -> String {
        var parts: [String] = []
        if let lastOpenError {
            parts.append(lastOpenError)
        }
        if let marker = Self.readBreachMarker(near: path) {
            parts.append(
                "repo.wax breached its live-set ceiling " +
                    "(allocated \(marker.allocatedBytes)B vs ~\(marker.expectedLiveBytes)B live" +
                    (marker.reclaimableBytes > 0 ? ", \(marker.reclaimableBytes)B reclaimable" : "") +
                    "); run 'cckit index . --clean' to rebuild from scratch."
            )
        }
        if parts.isEmpty {
            parts.append("store opened without embeddings")
        }
        return parts.joined(separator: " ")
    }

    private struct BreachMarkerInfo {
        let allocatedBytes: Int
        let expectedLiveBytes: Int
        let reclaimableBytes: Int
    }

    /// The CLI's bloat veto writes `wax-breach-marker.json` next to repo.wax
    /// when an arena stays over its ceiling. Read-path consumers (pack,
    /// search, serve) must surface it instead of blaming the MiniLM bundle —
    /// it sat unread for 5.5 hours during the 2026-08-27 186 GB incident
    /// while the tool diagnosed the one component that was working.
    private static func readBreachMarker(near waxPath: String) -> BreachMarkerInfo? {
        let dir = (waxPath as NSString).deletingLastPathComponent
        let markerPath = (dir as NSString).appendingPathComponent("wax-breach-marker.json")
        guard let data = FileManager.default.contents(atPath: markerPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func intValue(_ key: String) -> Int {
            (json[key] as? NSNumber)?.intValue ?? 0
        }
        let allocated = intValue("allocatedBytes")
        let expected = intValue("expectedLiveBytes")
        guard allocated > 0 else { return nil }
        return BreachMarkerInfo(
            allocatedBytes: allocated,
            expectedLiveBytes: expected,
            reclaimableBytes: intValue("reclaimableBytes")
        )
    }

    private func openMemory() async {
        let url = URL(fileURLWithPath: path)
        var config = Memory.Config.default
        config.embedding = .builtIn(.miniLM)
        do {
            let memory = try await Memory(at: url, config: config)
            let stats = await memory.stats()
            self.memory = memory
            self.embeddingsEnabled = stats.vectorSearchEnabled && stats.queryEmbedderConfigured
            self.lastOpenError = self.embeddingsEnabled ? nil : "Wax opened without a query embedder"
        } catch {
            let miniLMError = Self.describeOpenError(error)
            // Last-resort text-only open so non-semantic flows (token count) can
            // still work; semantic search will refuse via `requireEmbeddings()`.
            do {
                var textConfig = Memory.Config.default
                textConfig.enableVectorSearch = false
                self.memory = try await Memory(at: url, config: textConfig)
                self.embeddingsEnabled = false
                self.lastOpenError = "\(miniLMError); text-only open succeeded"
            } catch {
                self.memory = nil
                self.embeddingsEnabled = false
                self.lastOpenError = "Wax store failed to open: \(Self.describeOpenError(error)); MiniLM attempt: \(miniLMError)"
            }
        }
    }

    /// LocalizedError message when available, full description otherwise —
    /// `String(describing:)` on a Swift error often hides the useful part.
    static func describeOpenError(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let text = String(describing: error)
        return text.isEmpty ? String(describing: type(of: error)) : text
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

    /// Bytes currently materialized on disk for this arena (st_blocks).
    /// Public so index runs can enforce a mid-run growth cap (ask F) instead
    /// of discovering 186 GB after close.
    public func allocatedBytes() -> Int {
        Self.waxFileAllocatedBytes(at: path)
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

/// Result of ingesting one symbol into Wax. Current Wax returns no frame IDs;
/// the mandate is retained as durable cckit bookkeeping and search metadata.
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
    /// repo.wax allocation measured before the index operation.
    public let bytesBefore: Int
    /// Allocation observed after the store closes.
    public let bytesAfter: Int
    /// Files re-embedded by the index run that produced this result (0 for
    /// compact-only callers). Without these counts a ledger row cannot tell
    /// a 3 s no-op from a 21-minute near-full re-embed — the exact gap that
    /// made the 2026-08-27 186 GB incident undiagnosable from the ledger.
    public let updated: Int
    /// Files skipped (content hash unchanged) by the index run.
    public let skipped: Int
    /// Total symbols extracted by the index run.
    public let totalSymbols: Int
    /// True when cckit replaced the Wax arena instead of issuing incremental
    /// deletes. This is the safe compatibility path for Wax's public API.
    public let rebuiltWax: Bool

    /// True when the recorded sizes show an actual file shrink.
    public var shrank: Bool { bytesAfter < bytesBefore }

    public init(
        scanned: Int,
        deleted: Int,
        kept: Int,
        bytesBefore: Int = 0,
        bytesAfter: Int = 0,
        updated: Int = 0,
        skipped: Int = 0,
        totalSymbols: Int = 0,
        rebuiltWax: Bool = false
    ) {
        self.scanned = scanned
        self.deleted = deleted
        self.kept = kept
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.updated = updated
        self.skipped = skipped
        self.totalSymbols = totalSymbols
        self.rebuiltWax = rebuiltWax
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
        case embeddingsUnavailable(detail: String)

        public var errorDescription: String? {
            switch self {
            case .missingIndex:
                return "Index not found. Run 'cckit index .' first."
            case .outdated(let stored):
                let from = stored ?? "none"
                return "Semantic vector index is outdated (\(from) → \(current)). Run 'cckit index .' to rebuild."
            case .embeddingsUnavailable(let detail):
                // Only point at resource bundles when the bundle is actually
                // absent. During the 2026-08-27 186 GB incident this message
                // blamed MiniLM — which was working — for 5.5 hours while an
                // unopenable arena was the real cause.
                var message = "Semantic embeddings unavailable."
                if !detail.isEmpty {
                    message += " \(detail)"
                }
                if !Self.miniLMResourceBundleIsPresent() {
                    message += " Check Wax resource bundles (Wax_WaxVectorSearchMiniLM.bundle)."
                }
                return message
            }
        }

        /// True when the MiniLM Core ML model can be located next to the
        /// executable or Wax's own bundle. SPM CLI builds place resource
        /// bundles beside the binary; the honest check keeps the hint from
        /// firing when the bundle is present and something else broke.
        public static func miniLMResourceBundleIsPresent() -> Bool {
            let bundleName = "Wax_WaxVectorSearchMiniLM.bundle"
            let modelPath = "all-MiniLM-L6-v2.mlmodelc"
            let waxBundleURL = Bundle(for: Memory.self).bundleURL
            var candidates = [
                Bundle.main.bundleURL.appendingPathComponent(bundleName),
                waxBundleURL.appendingPathComponent(bundleName),
                waxBundleURL.deletingLastPathComponent().appendingPathComponent(bundleName),
            ]
            if let resourceURL = Bundle(for: Memory.self).resourceURL {
                candidates.append(resourceURL.appendingPathComponent(bundleName))
            }
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(modelPath).path) {
                    return true
                }
            }
            return false
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

    public struct Watermark {
        public let waxBytes: Int
        public let noShrinkRuns: Int
    }

    /// Parse an existing stamp; nil when missing or unparseable.
    /// The shim treats those identically ("never compacted"), but settle logic
    /// must NOT act on it — only a CLI-produced watermark counts as progress.
    public static func readWatermark(cckitDir: String = ".cckit") -> Watermark? {
        let path = (cckitDir as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let waxBytes = (obj["waxBytes"] as? NSNumber)?.intValue else {
            return nil
        }
        let noShrinkRuns = (obj["noShrinkRuns"] as? NSNumber)?.intValue ?? 0
        return Watermark(waxBytes: waxBytes, noShrinkRuns: noShrinkRuns)
    }

    /// Count one more consecutive no-progress compact while preserving the
    /// watermark verbatim. Returns the new count.
    @discardableResult
    public static func recordNoShrinkRun(cckitDir: String = ".cckit") throws -> Int {
        guard let watermark = readWatermark(cckitDir: cckitDir) else { return 0 }
        let runs = watermark.noShrinkRuns + 1
        try write(cckitDir: cckitDir, waxBytes: watermark.waxBytes, deletedFrames: 0, noShrinkRuns: runs)
        return runs
    }

    /// Relatch an allocated-bytes baseline. The convergence valve for a store
    /// that legitimately grew past its watermark yet has nothing reclaimable:
    /// without it the shim's needs-compact gate respawns no-op compacts
    /// forever. Future growth detection restarts from this new floor.
    public static func relatchBaseline(allocatedBytes: Int, cckitDir: String = ".cckit") throws {
        try write(cckitDir: cckitDir, waxBytes: allocatedBytes, deletedFrames: 0)
    }

    private static func write(
        cckitDir: String,
        waxBytes: Int,
        deletedFrames: Int,
        noShrinkRuns: Int = 0
    ) throws {
        let payload: [String: Any] = [
            "waxBytes": waxBytes,
            "deletedFrames": deletedFrames,
            "noShrinkRuns": noShrinkRuns,
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
