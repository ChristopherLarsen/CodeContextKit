import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval

/// Resolves pack targets once: exact qualified names first, then identifier
/// leaves, then optional semantic fill. File/leaf diversity applies only to
/// optional discovery hits.
public struct PacketTargetResolver: Sendable {
    let db: Database
    let wax: WaxStore?
    let rootPath: String
    let maxPrimarySymbols: Int

    public init(db: Database, wax: WaxStore?, rootPath: String, maxPrimarySymbols: Int) {
        self.db = db
        self.wax = wax
        self.rootPath = rootPath
        self.maxPrimarySymbols = maxPrimarySymbols
    }

    public func resolve(task: String) async throws -> PacketEvidence {
        var required: [ResolvedTarget] = []
        var optional: [ResolvedTarget] = []
        var seen = Set<DeclarationIdentity>()
        var omissions: [PacketOmission] = []
        var waxFillRan = false
        var waxHitCount = 0

        func append(_ symbol: SymbolRecord, required isRequired: Bool, request: String) {
            let identity = DeclarationIdentity(symbol)
            if seen.contains(identity) { return }
            // Overloads share a qualified name; identity includes signature + range.
            if isRequired {
                seen.insert(identity)
                required.append(ResolvedTarget(symbol: symbol, required: true, request: request))
            } else {
                seen.insert(identity)
                optional.append(ResolvedTarget(symbol: symbol, required: false, request: request))
            }
        }

        let queries = SemanticIndexPolicy.retrievalQueries(in: task)

        for qualified in queries.qualified {
            let exact = try db.getSymbols(qualifiedName: qualified)
            if exact.isEmpty {
                omissions.append(PacketOmission(targetID: qualified, reason: "not found"))
                continue
            }
            for symbol in exact {
                append(symbol, required: true, request: qualified)
                if symbol.kind.isType {
                    try addExtensions(of: symbol, request: qualified, append: append)
                }
            }
        }

        for leaf in queries.leaves {
            let likes = try db.getSymbolsLike(name: leaf, strict: true).filter { symbol in
                symbol.name == leaf
                    || symbol.qualifiedName == leaf
                    || symbol.qualifiedName.hasSuffix(".\(leaf)")
            }
            if likes.isEmpty {
                if !queries.qualified.contains(where: { $0.hasSuffix(".\(leaf)") || $0 == leaf }) {
                    omissions.append(PacketOmission(targetID: leaf, reason: "not found"))
                }
                continue
            }
            let ranked = likes.sorted { lhs, rhs in
                let lType = SemanticIndexPolicy.typeKinds.contains(lhs.kind)
                let rType = SemanticIndexPolicy.typeKinds.contains(rhs.kind)
                if lType != rType { return !lType && rType }
                return lhs.qualifiedName.count < rhs.qualifiedName.count
            }
            // Explicit leaf requests keep every distinct declaration (overloads,
            // same name in different types). No one-per-file / one-per-leaf drop.
            for symbol in ranked {
                append(symbol, required: true, request: leaf)
                if symbol.kind.isType {
                    try addExtensions(of: symbol, request: leaf, append: append)
                }
            }
        }

        let skipFiller = SemanticIndexPolicy.shouldSkipPackFiller(task: task)
        let remainingSlots = max(0, maxPrimarySymbols - required.count)
        if remainingSlots > 0 && !skipFiller, let wax {
            waxFillRan = true
            let searchResults = try await wax.search(task, limit: remainingSlots * 2)
            waxHitCount = searchResults.count
            var optionalFiles = Set(required.map(\.symbol.filePath))
            var optionalLeaves = Set(required.map(\.symbol.name))
            for result in searchResults {
                guard optional.count < remainingSlots else { break }
                let matches = try db.getSymbols(qualifiedName: result.symbol)
                let resolved = Self.resolveHit(result, candidates: matches)
                guard let symbol = resolved else { continue }
                let identity = DeclarationIdentity(symbol)
                if seen.contains(identity) { continue }
                if optionalFiles.contains(symbol.filePath) { continue }
                if optionalLeaves.contains(symbol.name) { continue }
                optionalFiles.insert(symbol.filePath)
                optionalLeaves.insert(symbol.name)
                append(symbol, required: false, request: result.symbol)
            }
        }

        let snapshots = try loadSnapshots(targets: required + optional)
        var remappedRequired: [ResolvedTarget] = []
        var remappedOptional: [ResolvedTarget] = []
        var contentStale = false

        func remap(_ target: ResolvedTarget) -> ResolvedTarget? {
            guard let snap = snapshots[target.symbol.filePath] else {
                omissions.append(PacketOmission(targetID: target.targetID, reason: "file unreadable"))
                return nil
            }
            let slice = FreshSymbolResolver.slice(
                symbol: target.symbol,
                content: snap.content,
                indexedHash: snap.indexedHash,
                currentHash: snap.currentHash
            )
            if snap.indexedHash != snap.currentHash {
                contentStale = true
            }
            if slice.locatorOnly {
                omissions.append(
                    PacketOmission(
                        targetID: target.targetID,
                        reason: "locator-only language (no implementation span)"
                    )
                )
            }
            if slice.body.isEmpty && !slice.locatorOnly && snap.indexedHash != snap.currentHash {
                omissions.append(
                    PacketOmission(targetID: target.targetID, reason: "stale index; symbol not found in current file")
                )
                return nil
            }
            var updated = target
            updated.symbol = slice.symbol
            updated.identity = DeclarationIdentity(slice.symbol)
            return updated
        }

        for target in required {
            if let mapped = remap(target) {
                remappedRequired.append(mapped)
            }
        }
        for target in optional {
            if let mapped = remap(target) {
                remappedOptional.append(mapped)
            }
        }

        let mergedRequired = Self.mergeOverlapping(remappedRequired)
        return PacketEvidence(
            required: mergedRequired,
            optional: remappedOptional,
            sourceHashes: snapshots.mapValues(\.currentHash),
            indexedHashes: snapshots.compactMapValues(\.indexedHash),
            fileContents: snapshots.mapValues(\.content),
            omissions: omissions,
            waxFillRan: waxFillRan,
            waxHitCount: waxHitCount,
            contentStale: contentStale
        )
    }

    private func addExtensions(
        of symbol: SymbolRecord,
        request: String,
        append: (SymbolRecord, Bool, String) -> Void
    ) throws {
        let fileSymbols = try db.getSymbols(path: symbol.filePath)
        for ext in FreshSymbolResolver.extensions(of: symbol.name, in: fileSymbols) {
            append(ext, true, request)
        }
        // Extensions may live in other files.
        let likes = try db.getSymbolsLike(name: symbol.name, strict: true)
        for ext in likes where ext.kind == .extension && ext.name == symbol.name {
            append(ext, true, request)
        }
    }

    private struct Snapshot {
        var content: String
        var currentHash: String
        var indexedHash: String?
    }

    private func loadSnapshots(targets: [ResolvedTarget]) throws -> [String: Snapshot] {
        let hasher = FileHasher()
        let rootURL = URL(fileURLWithPath: rootPath)
        var out: [String: Snapshot] = [:]
        for path in Set(targets.map(\.symbol.filePath)) {
            let url = rootURL.appendingPathComponent(path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let indexedHash = try db.getFile(path: path)?.sha256
            out[path] = Snapshot(
                content: content,
                currentHash: hasher.hash(content: content),
                indexedHash: indexedHash
            )
        }
        return out
    }

    /// Prefer the declaration whose file (and range, when Wax recorded it) matches the hit.
    public static func resolveHit(_ result: SearchResult, candidates: [SymbolRecord]) -> SymbolRecord? {
        if candidates.isEmpty { return nil }
        let inFile = candidates.filter { $0.filePath == result.file }
        let pool = inFile.isEmpty ? candidates : inFile
        if let start = result.startLine, let end = result.endLine {
            if let ranged = pool.first(where: { $0.startLine == start && $0.endLine == end }) {
                return ranged
            }
        }
        if let signature = result.signature, !signature.isEmpty {
            if let signed = pool.first(where: { $0.signature == signature }) {
                return signed
            }
        }
        return pool.first
    }

    /// Union overlapping body ranges for distinct requested declarations in one file
    /// instead of dropping one of them.
    public static func mergeOverlapping(_ targets: [ResolvedTarget]) -> [ResolvedTarget] {
        guard targets.count > 1 else { return targets }
        var byFile: [String: [ResolvedTarget]] = [:]
        for target in targets {
            byFile[target.symbol.filePath, default: []].append(target)
        }
        var out: [ResolvedTarget] = []
        for (_, group) in byFile {
            let sorted = group.sorted { $0.symbol.startLine < $1.symbol.startLine }
            var current = sorted[0]
            for next in sorted.dropFirst() {
                if next.symbol.startLine <= current.symbol.endLine {
                    var merged = current.symbol
                    merged.endLine = max(current.symbol.endLine, next.symbol.endLine)
                    if !current.symbol.qualifiedName.contains(next.symbol.name) {
                        merged.qualifiedName = current.symbol.qualifiedName + "+" + next.symbol.name
                        merged.name = current.symbol.name + "+" + next.symbol.name
                    }
                    current.symbol = merged
                    current.identity = DeclarationIdentity(merged)
                } else {
                    out.append(current)
                    current = next
                }
            }
            out.append(current)
        }
        return out.sorted { $0.symbol.filePath == $1.symbol.filePath
            ? $0.symbol.startLine < $1.symbol.startLine
            : $0.symbol.filePath < $1.symbol.filePath }
    }
}
