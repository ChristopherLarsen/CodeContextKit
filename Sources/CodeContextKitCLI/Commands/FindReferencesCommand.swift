import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

/// Reverse lookup of indexed references/call sites for a symbol name (no bodies).
struct FindReferencesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-references",
        abstract: "Find indexed references/call sites for a symbol name (paths and lines, no bodies)."
    )

    @Argument(help: "Symbol leaf name or qualified name (leaf is used for lookup).")
    var name: String

    @Option(help: "Maximum hits to return.")
    var limit: Int = 100

    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }

        let db = try Database(path: dbPath)
        let leaf = SymbolRanking.leafName(name)

        // Resolution ladder: exact leaf → normalized variants → names
        // containing the leaf → did-you-mean candidates from the symbol table.
        // Each rung avoids a repo-wide Grep fallback for near-name queries.
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
            let loose = try db.getReferencesLike(name: leaf, limit: max(1, limit))
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

        let totalCount = refs.count
        let cappedLimit = max(1, limit)
        let truncated = totalCount > cappedLimit
        let limited = Array(refs.prefix(cappedLimit))

        var blockParts: [String] = []
        if matchMode == "contains" && totalCount > 0 {
            blockParts.append(
                "Approximate: reference names containing '\(leaf)' — verify before editing."
            )
        }
        if !candidates.isEmpty {
            blockParts.append(
                "No references to '\(leaf)'. Did you mean: \(candidates.joined(separator: ", "))?"
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
            leaf: matchedAs,
            hits: hits,
            totalCount: totalCount,
            truncated: truncated
        )
        let annotatedBlock =
            blockParts.isEmpty
                ? resultsBlock
                : resultsBlock + "\n\n" + blockParts.joined(separator: "\n")

        let freshness = IndexFreshness.check(repoRoot: ".")
        let responseText: String

        if json {
            var payload: [String: Any] = [
                "totalCount": totalCount,
                "truncated": truncated,
                "limit": cappedLimit,
                "matchMode": matchMode,
                "results": annotatedBlock,
            ]
            if matchedAs != leaf {
                payload["matchedAs"] = matchedAs
            }
            if !candidates.isEmpty {
                payload["candidates"] = candidates
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
            lines.append(resultsBlock)
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
