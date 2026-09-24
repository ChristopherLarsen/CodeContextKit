import ArgumentParser
import Foundation
import CodeContextKitContext
import CodeContextKitCore

/// Prints pack token-savings and tool usage from `.cckit/` ledgers, grouped by day.
struct PackStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack-stats",
        abstract: "Show pack savings and tool usage from .cckit ledgers, grouped by day."
    )

    @Option(name: .shortAndLong, help: "Repository root containing .cckit/ (default: .).")
    var path: String = "."

    @Flag(help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        let root = resolvePath(path)
        let ledger = PackSavingsLedger(repoRoot: root)
        let history = ActionHistoryStore(repoRoot: root)
        let entries = try ledger.loadEntries()
        let byDay = try ledger.savingsByDay()
        let actions = try history.loadEntries()
        let dedup = PackSavingsLedger.readDedupSavings(cckitDir: ledger.cckitDir)

        // Monthly rollups survive the 7-day JSONL window; combine with live rows
        // so lifetime numbers keep growing after old rows are evicted.
        let monthlyRollups = LedgerRollups.loadSavings(cckitDir: ledger.cckitDir)
        let monthlyTools = LedgerRollups.loadTools(cckitDir: history.cckitDir)
        let lifetimeTools = LedgerRollups.mergeToolUsage(
            rollups: monthlyTools,
            live: actions,
            liveSavings: entries
        )

        let liveSaved = entries.map(\.tokensSaved).reduce(0, +)
        let liveDelivered = entries.map(\.deliveredTokens).reduce(0, +)
        let liveSource = entries.map(\.sourceWholeFileTokens).reduce(0, +)
        let lifetimePacks = monthlyRollups.map(\.packs).reduce(0, +) + entries.count
        let lifetimeSaved = monthlyRollups.map(\.tokensSaved).reduce(0, +) + liveSaved
        let lifetimeDelivered = monthlyRollups.map(\.deliveredTokens).reduce(0, +) + liveDelivered
        let lifetimeSource = monthlyRollups.map(\.sourceWholeFileTokens).reduce(0, +) + liveSource

        let totalSaved = liveSaved
        let totalDelivered = liveDelivered
        let totalSource = liveSource
        let overallPct = PackSavingsLedger.savingsPercentOfUsage(
            saved: totalSaved,
            sourceWholeFileTokens: totalSource
        )
        let lifetimePct = PackSavingsLedger.savingsPercentOfUsage(
            saved: lifetimeSaved,
            sourceWholeFileTokens: lifetimeSource
        )

        var toolBuckets: [String: (count: Int, tokens: Int, avoided: Int, source: Int)] = [:]
        var callerBuckets: [String: (count: Int, tokens: Int)] = [:]
        for action in actions {
            let key = action.toolName ?? action.type
            let prior = toolBuckets[key] ?? (0, 0, 0, 0)
            toolBuckets[key] = (
                prior.count + 1,
                prior.tokens + action.tokensUsed,
                prior.avoided + action.tokensAvoidedVersusSourceFile,
                prior.source + action.sourceWholeFileTokens
            )
            let caller = action.type
            let cPrior = callerBuckets[caller] ?? (0, 0)
            callerBuckets[caller] = (cPrior.count + 1, cPrior.tokens + action.tokensUsed)
        }

        if json {
            let payload: [String: Any] = [
                "ledger": ledger.fileURL.path,
                "actionHistory": history.fileURL.path,
                "packs": entries.count,
                "totalDelivered": totalDelivered,
                "totalSourceWholeFileTokens": totalSource,
                "totalSaved": totalSaved,
                "savingsPercentOfSource": overallPct as Any,
                "lifetime": [
                    "packs": lifetimePacks,
                    "tokensDelivered": lifetimeDelivered,
                    "sourceWholeFileTokens": lifetimeSource,
                    "tokensSaved": lifetimeSaved,
                    "savingsPercentOfSource": lifetimePct as Any,
                ] as [String: Any],
                "months": monthlyRollups.map { rollup in
                    [
                        "month": rollup.monthKey,
                        "packs": rollup.packs,
                        "tokensDelivered": rollup.deliveredTokens,
                        "sourceWholeFileTokens": rollup.sourceWholeFileTokens,
                        "tokensSaved": rollup.tokensSaved,
                        "savingsPercentOfSource": PackSavingsLedger.savingsPercentOfUsage(
                            saved: rollup.tokensSaved,
                            sourceWholeFileTokens: rollup.sourceWholeFileTokens
                        ) as Any,
                    ] as [String: Any]
                },
                "days": byDay.map { day, saved, delivered, source, packs in
                    [
                        "day": ISO8601DateFormatter().string(from: day),
                        "label": PackSavingsLedger.formatDayLabel(day),
                        "tokensSaved": saved,
                        "tokensDelivered": delivered,
                        "sourceWholeFileTokens": source,
                        "savingsPercentOfSource": PackSavingsLedger.savingsPercentOfUsage(
                            saved: saved,
                            sourceWholeFileTokens: source
                        ) as Any,
                        "packs": packs,
                    ] as [String: Any]
                },
                "tools": toolBuckets.keys.sorted().map { name in
                    let value = toolBuckets[name]!
                    return [
                        "tool": name,
                        "calls": value.count,
                        "tokensUsed": value.tokens,
                        "sourceWholeFileTokens": value.source,
                        "tokensAvoidedVersusSourceFile": value.avoided,
                    ] as [String: Any]
                },
                "lifetimeTools": lifetimeTools.keys.sorted().map { name in
                    Self.lifetimeToolJSON(name: name, totals: lifetimeTools[name]!)
                },
                "toolMonths": monthlyTools.map { rollup in
                    [
                        "month": rollup.monthKey,
                        "tool": rollup.tool,
                        "calls": rollup.calls,
                        "tokensUsed": rollup.tokensUsed,
                        "failedCount": rollup.failedCount,
                        "zeroPrimaryCount": rollup.zeroPrimaryCount,
                        "reasons": rollup.reasons,
                    ] as [String: Any]
                },
                "callers": callerBuckets.keys.sorted().map { name in
                    let value = callerBuckets[name]!
                    return [
                        "type": name,
                        "calls": value.count,
                        "tokensUsed": value.tokens,
                    ] as [String: Any]
                },
                "dedup": [
                    "stubs": dedup.calls,
                    "tokensSaved": dedup.tokensSaved,
                    "byTool": Dictionary(uniqueKeysWithValues: dedup.byTool.map {
                        ($0.key, ["calls": $0.value.calls, "tokensSaved": $0.value.tokensSaved] as [String: Any])
                    }),
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        if entries.isEmpty && actions.isEmpty && monthlyRollups.isEmpty && monthlyTools.isEmpty {
            print("No pack savings or tool usage recorded yet.")
            print("Ledger:  \(ledger.fileURL.path)")
            print("Actions: \(history.fileURL.path)")
            return
        }

        if !entries.isEmpty {
            print("Pack savings (vs whole source files already loaded into packets)")
            print("  (not vs Grep or other tools — dual-running those spends the tokens claimed)")
            print("  ledger:    \(ledger.fileURL.path)")
            print("  packs:     \(entries.count)")
            print("  delivered: \(PackSavingsLedger.formatTokenCount(totalDelivered)) tokens")
            print("  source:    \(PackSavingsLedger.formatTokenCount(totalSource)) tokens (whole files)")
            print("  saved:     \(PackSavingsLedger.formatSavingsLine(saved: totalSaved, sourceWholeFileTokens: totalSource))")
            print("")
            if !monthlyRollups.isEmpty {
                print("By month (rollups survive the 7-day ledger window):")
                for rollup in monthlyRollups.suffix(12) {
                    let pct = PackSavingsLedger.savingsPercentOfUsage(
                        saved: rollup.tokensSaved,
                        sourceWholeFileTokens: rollup.sourceWholeFileTokens
                    )
                    let pctText = pct.map { String(format: "%.1f%%", $0) } ?? "n/a"
                    print("  \(rollup.monthKey): saved \(PackSavingsLedger.formatTokenCount(rollup.tokensSaved)) · "
                        + "delivered \(PackSavingsLedger.formatTokenCount(rollup.deliveredTokens)) · "
                        + "source \(PackSavingsLedger.formatTokenCount(rollup.sourceWholeFileTokens)) · "
                        + "\(pctText) of source (\(rollup.packs) pack\(rollup.packs == 1 ? "" : "s"))")
                }
                var lifetimeLine = "  lifetime (\(lifetimePacks) packs incl. rolled-up months): "
                lifetimeLine += "saved \(PackSavingsLedger.formatTokenCount(lifetimeSaved))"
                if let lifetimePct {
                    lifetimeLine += String(format: " (%.1f%% of source)", lifetimePct)
                }
                print(lifetimeLine)
                print("")
            }
            print("By day:")
            for (day, saved, _, source, packs) in byDay.reversed() {
                let label = PackSavingsLedger.formatDayLabel(day)
                print("  \(label): \(PackSavingsLedger.formatSavingsLine(saved: saved, sourceWholeFileTokens: source, packs: packs))")
            }
            print("")
        }

        if dedup.calls > 0 {
            print("Dedup savings (stubbed re-deliveries of unchanged content)")
            print(
                "  ledger: \(ledger.cckitDir.appendingPathComponent("dedup_savings.jsonl").path)"
            )
            print(
                "  stubs:  \(dedup.calls) · saved "
                    + "\(PackSavingsLedger.formatTokenCount(dedup.tokensSaved)) tokens"
            )
            for tool in dedup.byTool.keys.sorted() {
                let value = dedup.byTool[tool]!
                print(
                    "  \(tool): \(value.calls) · saved "
                        + "\(PackSavingsLedger.formatTokenCount(value.tokensSaved)) tokens"
                )
            }
            print("")
        }

        if !actions.isEmpty {
            print("Tool usage (from \(history.fileURL.path))")
            print("  (tokensUsed = serialized response estimate;")
            print("   avoided = vs whole files already read by that call, when known;")
            print("   not vs Grep — dual-running Grep spends the tokens claimed)")
            for name in toolBuckets.keys.sorted() {
                let value = toolBuckets[name]!
                var line =
                    "  \(name): \(value.count) call\(value.count == 1 ? "" : "s") · "
                    + "\(PackSavingsLedger.formatTokenCount(value.tokens)) tokens delivered"
                if value.source > 0 {
                    line +=
                        " · avoided \(PackSavingsLedger.formatTokenCount(value.avoided))"
                        + " vs \(PackSavingsLedger.formatTokenCount(value.source)) whole-file"
                }
                print(line)
            }
            if callerBuckets.count > 1 || callerBuckets.keys.contains("mcp") {
                print("")
                print("By caller:")
                for name in callerBuckets.keys.sorted() {
                    let value = callerBuckets[name]!
                    print(
                        "  \(name): \(value.count) call\(value.count == 1 ? "" : "s") · "
                            + "\(PackSavingsLedger.formatTokenCount(value.tokens)) tokens"
                    )
                }
            }
        }

        if !lifetimeTools.isEmpty {
            print("")
            print("Lifetime tool calls (incl. rolled-up months and current window):")
            for name in lifetimeTools.keys.sorted() {
                let value = lifetimeTools[name]!
                var line =
                    "  \(name): \(value.calls) call\(value.calls == 1 ? "" : "s") · "
                    + "\(PackSavingsLedger.formatTokenCount(value.tokensUsed)) tokens"
                if value.failedCount > 0 || value.zeroPrimaryCount > 0 {
                    line +=
                        " · \(value.failedCount) failed · \(value.zeroPrimaryCount) empty"
                }
                let histogram = LedgerRollups.formatReasonHistogram(value.reasons)
                if !histogram.isEmpty, value.failedCount > 0 || value.zeroPrimaryCount > 0
                    || (value.reasons[LedgerOutcome.preview] ?? 0) > 0
                {
                    line += " · \(histogram)"
                }
                print(line)
            }
            if let pack = lifetimeTools["pack"], pack.calls > 0 {
                let previewCount = pack.reasons[LedgerOutcome.preview] ?? 0
                let empty = max(0, pack.calls - lifetimePacks - pack.failedCount - previewCount)
                print("")
                print("Pack outcomes (failed/empty survive monthly rollup):")
                print(
                    "  lifetime: \(pack.calls) calls · \(lifetimePacks) productive · "
                        + "\(pack.failedCount) failed · \(empty) empty"
                )
                let packMonths = monthlyTools.filter { $0.tool == "pack" }
                let savingsByMonth = Dictionary(
                    uniqueKeysWithValues: monthlyRollups.map { ($0.monthKey, $0.packs) }
                )
                for rollup in packMonths {
                    let productiveKnown = rollup.reasons[LedgerOutcome.productive] ?? 0
                    let inferredEmpty = rollup.failedCount == 0
                        && rollup.zeroPrimaryCount == 0
                        && rollup.reasons.isEmpty
                    let productive = inferredEmpty
                        ? (savingsByMonth[rollup.monthKey] ?? 0)
                        : productiveKnown
                    let empty = inferredEmpty
                        ? max(0, rollup.calls - productive)
                        : rollup.zeroPrimaryCount
                    var line =
                        "  \(rollup.monthKey): \(rollup.calls) calls · \(productive) productive · "
                        + "\(rollup.failedCount) failed · \(empty) empty"
                    let histogram = LedgerRollups.formatReasonHistogram(rollup.reasons)
                    if !histogram.isEmpty {
                        line += " · \(histogram)"
                    } else if inferredEmpty && rollup.calls > productive {
                        line += " · (pre-histogram rollup; empty includes failed)"
                    }
                    print(line)
                }
            }
        }
    }

    private func resolvePath(_ raw: String) -> String {
        if raw.hasPrefix("/") { return raw }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(raw)
            .standardizedFileURL
            .path
    }

    private static func lifetimeToolJSON(name: String, totals: ToolUsageTotals) -> [String: Any] {
        [
            "tool": name,
            "calls": totals.calls,
            "tokensUsed": totals.tokensUsed,
            "failedCount": totals.failedCount,
            "zeroPrimaryCount": totals.zeroPrimaryCount,
            "productiveCount": totals.productiveCount,
            "reasons": totals.reasons,
        ]
    }
}
