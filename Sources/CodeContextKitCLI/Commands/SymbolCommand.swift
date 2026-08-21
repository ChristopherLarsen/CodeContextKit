import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

struct SymbolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "symbol",
        abstract: "Retrieves symbol implementation(s) by qualified name (batch-capable)."
    )

    @Argument(help: "One or more qualified symbol names (or leaf names with fallback).")
    var names: [String]

    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }
        guard !names.isEmpty else {
            print("Error: pass at least one symbol name.")
            throw ExitCode.failure
        }

        let db = try Database(path: dbPath)
        let freshness = IndexFreshness.check(repoRoot: ".")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        var symbolItems: [[String: Any]] = []
        var candidateBlocks: [String] = []
        var missBlocks: [String] = []
        var resolvedSymbols: [SymbolRecord] = []
        var seenQualified = Set<String>()

        for requested in names {
            let outcome = try SymbolBodyResolver.resolve(requested: requested, db: db)
            switch outcome {
            case .bodies(let symbols, let resolvedFrom):
                for sym in symbols where seenQualified.insert(sym.qualifiedName).inserted {
                    resolvedSymbols.append(sym)
                    if let omission = try SymbolBodyResolver.hugeOmission(for: sym, db: db) {
                        symbolItems.append(
                            SymbolBodyResolver.slimPayload(
                                symbol: sym,
                                body: "",
                                resolvedFrom: resolvedFrom,
                                omitted: omission.reason,
                                members: omission.members
                            )
                        )
                    } else {
                        let body = Self.readBody(symbol: sym, repoRoot: root)
                        symbolItems.append(
                            SymbolBodyResolver.slimPayload(
                                symbol: sym,
                                body: body,
                                resolvedFrom: resolvedFrom
                            )
                        )
                    }
                }
            case .candidates(let block):
                candidateBlocks.append(block)
            case .miss(let block):
                missBlocks.append(block)
            }
        }

        let responseText: String
        var deliveredTokens = 0
        var sourceTokens = 0
        if json {
            var payload: [String: Any] = [
                "count": symbolItems.count,
                "symbols": symbolItems,
            ]
            if !candidateBlocks.isEmpty {
                payload["candidates"] = candidateBlocks.joined(separator: "\n\n")
            }
            if !missBlocks.isEmpty {
                payload["misses"] = missBlocks.joined(separator: "\n\n")
            }
            // Savings feedback (see PackCommand PACK_STATS): estimate the
            // delivery without the stats keys, then attach them.
            let provisional = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            deliveredTokens = TokenEstimator.shared.estimate(provisional)
            sourceTokens = Self.sourceWholeFileTokens(for: resolvedSymbols, root: root)
            if sourceTokens > 0 {
                payload["tokensDelivered"] = deliveredTokens
                payload["sourceWholeFileTokens"] = sourceTokens
                payload["tokensSaved"] = sourceTokens - deliveredTokens
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
            for item in symbolItems {
                let qn = item["qualifiedName"] as? String ?? "?"
                let kind = item["kind"] as? String ?? "?"
                let path = item["filePath"] as? String ?? "?"
                let start = item["startLine"] as? Int ?? 0
                let end = item["endLine"] as? Int ?? 0
                lines.append("Symbol: \(qn)")
                lines.append("Kind: \(kind)")
                lines.append("File: \(path):\(start)-\(end)")
                if let from = item["resolvedFrom"] as? String {
                    lines.append("Resolved from: \(from)")
                }
                lines.append(String(repeating: "-", count: 20))
                if let omitted = item["omitted"] as? String {
                    lines.append(omitted)
                    if let members = item["members"] as? String, !members.isEmpty {
                        lines.append("Members:")
                        lines.append(members)
                    }
                } else {
                    let body = item["body"] as? String ?? ""
                    lines.append(body.isEmpty ? "(body unavailable)" : body)
                }
                lines.append("")
            }
            for block in candidateBlocks {
                lines.append("Candidates:")
                lines.append(block)
                lines.append("")
            }
            for block in missBlocks {
                lines.append(block)
                lines.append("")
            }
            if symbolItems.isEmpty && candidateBlocks.isEmpty && missBlocks.isEmpty {
                lines.append("No symbol found.")
            }
            responseText = lines.joined(separator: "\n")
            print(responseText)
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        if deliveredTokens == 0 {
            deliveredTokens = TokenEstimator.shared.estimate(responseText)
        }
        if sourceTokens == 0 {
            sourceTokens = Self.sourceWholeFileTokens(for: resolvedSymbols, root: root)
        }
        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "symbol",
            durationMs: duration,
            tokensUsed: deliveredTokens,
            sourceWholeFileTokens: sourceTokens
        )
    }

    private static func sourceWholeFileTokens(for symbols: [SymbolRecord], root: URL) -> Int {
        var total = 0
        var seenFiles = Set<String>()
        for symbol in symbols where seenFiles.insert(symbol.filePath).inserted {
            let url = symbol.filePath.hasPrefix("/")
                ? URL(fileURLWithPath: symbol.filePath)
                : root.appendingPathComponent(symbol.filePath)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                total += TokenEstimator.shared.estimate(content)
            }
        }
        return total
    }

    private static func readBody(symbol: SymbolRecord, repoRoot: URL) -> String {
        let url: URL
        if symbol.filePath.hasPrefix("/") {
            url = URL(fileURLWithPath: symbol.filePath)
        } else {
            url = repoRoot.appendingPathComponent(symbol.filePath)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return LineRangeBodyExtractor.body(for: symbol, content: content)
    }
}
