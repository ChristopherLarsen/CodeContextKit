import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

/// Lightweight name lookup: qualified names + paths, no bodies.
struct FindSymbolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-symbol",
        abstract: "Find symbols by name fragment (qualified names and paths, no bodies)."
    )

    @Argument(help: "Name fragment to match against symbol name / qualifiedName.")
    var name: String

    @Option(help: "Maximum hits to return.")
    var limit: Int = 20

    @Flag(help: "Require every whitespace-separated term to match (AND).")
    var strict: Bool = false

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
        var matches = try db.getSymbolsLike(name: name, strict: strict)
        var matchedViaVariant: String?
        if matches.isEmpty {
            // Zero hits: retry normalized variants (snake_case ↔ CamelCase drift)
            // so agents do not fall back to repo-wide Grep.
            for variant in SymbolRanking.queryVariants(for: name) {
                let variantMatches = try db.getSymbolsLike(name: variant, strict: strict)
                if !variantMatches.isEmpty {
                    matches = variantMatches
                    matchedViaVariant = variant
                    break
                }
            }
        }
        let (hits, totalMerged, truncated) = SymbolRanking.rankMergeLimit(
            matches,
            query: name,
            limit: max(1, limit)
        )
        let resultsBlock = SymbolRanking.formatGroupedBlock(
            hits: hits,
            query: name,
            totalMerged: totalMerged,
            truncated: truncated
        )

        let freshness = IndexFreshness.check(repoRoot: ".")
        let responseText: String

        if json {
            var payload: [String: Any] = [
                "count": hits.count,
                "totalCount": totalMerged,
                "truncated": truncated,
                "results": resultsBlock,
            ]
            if let via = matchedViaVariant {
                payload["matchedViaVariant"] = via
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
        // Auditable savings baseline (rg whole-repo, -1 unmeasured). Bimodal
        // by design: ~17-147x win on common names, ~1x on rare ones — worth
        // seeing in the ledger instead of logging 0 forever.
        let baseline = LexicalBaseline.tokens(for: name, repoRoot: ".")
        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "find-symbol",
            durationMs: duration,
            tokensUsed: tokens,
            baselineTokens: baseline
        )
    }
}
