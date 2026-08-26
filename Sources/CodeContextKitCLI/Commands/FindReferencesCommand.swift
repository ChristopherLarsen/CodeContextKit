import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

/// Reverse lookup of indexed references/call sites for symbol names (no bodies).
/// Accepts one name or a batch; batched output nests under `batches`.
struct FindReferencesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-references",
        abstract: "Find indexed references/call sites for symbol names (paths and lines, no bodies)."
    )

    @Argument(help: "One or more symbol leaf/qualified names (leaf is used for lookup).")
    var names: [String]

    @Option(help: "Maximum hits per name to return.")
    var limit: Int = 100

    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    private struct Resolution {
        let leaf: String
        let matchedAs: String
        let matchMode: String
        let refs: [SymbolRecord.Reference]
        let candidates: [String]
    }

    /// Exact leaf → normalized variants → names containing the leaf →
    /// did-you-mean candidates from the symbol table. Each rung avoids a
    /// repo-wide Grep fallback for near-name queries.
    private func resolve(
        _ requested: String,
        db: Database,
        limit: Int
    ) throws -> Resolution {
        let leaf = SymbolRanking.leafName(requested)

        var refs = try db.getReferences(forSymbolName: leaf)
        var matchedAs = leaf
        var matchMode = "exact"

        if refs.isEmpty {
            for variant in SymbolRanking.queryVariants(for: leaf) {
                let variantLeaf = SymbolRanking.leafName(variant)
                let variantRefs = try db.getReferences(forSymbolName: variantLeaf)
                if !variantRefs.isEmpty {
                    refs = variantRefs
                    matchedAs = variantLeaf
                    matchMode = "variant"
                    break
                }
            }
        }

        if refs.isEmpty {
            let loose = try db.getReferencesLike(name: leaf, limit: limit)
            if !loose.isEmpty {
                refs = loose
                matchedAs = leaf
                matchMode = "contains"
            }
        }

        var candidates: [String] = []
        if refs.isEmpty {
            let similar = try db.getSymbolsLike(name: leaf, strict: false)
            candidates = SymbolRanking.ranked(similar, query: leaf)
                .prefix(5)
                .map(\.qualifiedName)
        }

        return Resolution(
            leaf: leaf,
            matchedAs: matchedAs,
            matchMode: matchMode,
            refs: refs,
            candidates: candidates
        )
    }

    private func makeBlock(for name: String, resolution: Resolution, limit: Int) -> (
        block: String,
        totalCount: Int,
        truncated: Bool,
        item: [String: Any]
    ) {
        let totalCount = resolution.refs.count
        let truncated = totalCount > limit
        let limited = Array(resolution.refs.prefix(limit))

        var notes: [String] = []
        if resolution.matchMode == "contains" && totalCount > 0 {
            notes.append(
                "Approximate: reference names containing '\(resolution.leaf)' — verify before editing."
            )
        }
        if !resolution.candidates.isEmpty {
            notes.append(
                "No references to '\(resolution.leaf)'. Did you mean: "
                    + resolution.candidates.joined(separator: ", ") + "?"
            )
        }

        let hits = limited.map {
            ReferenceResultFormatting.Hit(
                filePath: $0.file ?? "",
                startLine: $0.startLine,
                context: $0.context
            )
        }
        let resultsBlock = ReferenceResultFormatting.formatBlock(
            leaf: resolution.matchedAs,
            hits: hits,
            totalCount: totalCount,
            truncated: truncated
        )
        let annotatedBlock =
            notes.isEmpty
                ? resultsBlock
                : resultsBlock + "\n\n" + notes.joined(separator: "\n")

        var item: [String: Any] = [
            "name": name,
            "matchMode": resolution.matchMode,
            "totalCount": totalCount,
            "truncated": truncated,
            "results": annotatedBlock,
        ]
        if resolution.matchedAs != resolution.leaf {
            item["matchedAs"] = resolution.matchedAs
        }
        if !resolution.candidates.isEmpty {
            item["candidates"] = resolution.candidates
        }
        return (annotatedBlock, totalCount, truncated, item)
    }

    func run() async throws {
        let startTime = Date()
        guard !names.isEmpty else {
            print("Error: pass at least one symbol name.")
            throw ExitCode.failure
        }
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }

        let db = try Database(path: dbPath)
        let cappedLimit = max(1, limit)

        var batches: [[String: Any]] = []
        var blocks: [String] = []
        var totalCountAll = 0
        for requested in names {
            let resolution = try resolve(requested, db: db, limit: cappedLimit)
            let built = makeBlock(
                for: requested,
                resolution: resolution,
                limit: cappedLimit
            )
            batches.append(built.item)
            blocks.append(built.block)
            totalCountAll += built.totalCount
        }

        let freshness = IndexFreshness.check(repoRoot: ".")
        let responseText: String

        if json {
            var payload: [String: Any]
            if batches.count == 1 {
                // Single-name shape is unchanged (backward compatible).
                payload = batches[0]
                payload["limit"] = cappedLimit
            } else {
                payload = [
                    "limit": cappedLimit,
                    "totalCount": totalCountAll,
                    "batches": batches,
                ]
            }
            for (key, value) in freshness.compactDictionary {
                payload[key] = value
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            responseText = String(decoding: data, as: UTF8.self)
            print(responseText)
        } else {
            var lines: [String] = []
            if let warning = freshness.softWarning {
                lines.append(warning)
            }
            lines.append(blocks.joined(separator: "\n\n"))
            responseText = lines.joined(separator: "\n")
            print(responseText)
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        let tokens = TokenEstimator.shared.estimate(responseText)
        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "find-references",
            durationMs: duration,
            tokensUsed: tokens
        )
    }
}
