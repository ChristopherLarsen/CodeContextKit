import XCTest
import Foundation
import CodeContextKitCore
@testable import CodeContextKitContext

final class PackSavingsLedgerTests: XCTestCase {
    func testAppendAndGroupByDay() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        // Two distinct calendar days, both well inside the 7-day window.
        let day1 = cal.date(byAdding: .day, value: -2, to: todayStart)!
            .addingTimeInterval(10 * 3600) // 10:00
        let day1b = day1.addingTimeInterval(8 * 3600) // 18:00 same day
        let day2 = cal.date(byAdding: .day, value: -1, to: todayStart)!
            .addingTimeInterval(9 * 3600) // 09:00

        try ledger.append(PackSavingsEntry(
            timestamp: day1,
            task: "a",
            repo: "/tmp",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 1000,
            surgicalTokens: 1000,
            fullBaselineTokens: 1500,
            sourceWholeFileTokens: 1500,
            tokensSaved: 500,
            budget: 12000
        ), now: now)
        try ledger.append(PackSavingsEntry(
            timestamp: day1b,
            task: "b",
            repo: "/tmp",
            requestedMode: "auto",
            deliveredMode: "full",
            deliveredTokens: 2000,
            surgicalTokens: 2200,
            fullBaselineTokens: 2000,
            sourceWholeFileTokens: 2000,
            tokensSaved: 0,
            budget: 12000
        ), now: now)
        try ledger.append(PackSavingsEntry(
            timestamp: day2,
            task: "c",
            repo: "/tmp",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 800,
            surgicalTokens: 800,
            fullBaselineTokens: 2035,
            sourceWholeFileTokens: 2035,
            tokensSaved: 1235,
            budget: 12000
        ), now: now)

        let byDay = try ledger.savingsByDay(
            timeZone: TimeZone(secondsFromGMT: 0)!,
            calendar: cal,
            now: now
        )
        XCTAssertEqual(byDay.count, 2)
        XCTAssertEqual(byDay[0].tokensSaved, 500)
        XCTAssertEqual(byDay[0].tokensDelivered, 3000)
        XCTAssertEqual(byDay[0].sourceWholeFileTokens, 3500)
        XCTAssertEqual(byDay[0].packs, 2)
        XCTAssertEqual(byDay[1].tokensSaved, 1235)
        XCTAssertEqual(byDay[1].packs, 1)

        let pct = PackSavingsLedger.savingsPercentOfUsage(saved: 1235, sourceWholeFileTokens: 2035)
        XCTAssertEqual(pct!, 1235.0 / 2035.0 * 100.0, accuracy: 0.01)
        XCTAssertEqual(
            PackSavingsLedger.formatSavingsLine(saved: 1235, sourceWholeFileTokens: 2035, packs: 1),
            "1,235 tokens saved vs whole files · 60.7% of source (1 pack)"
        )

        let label = PackSavingsLedger.formatDayLabel(day2, now: day2, calendar: cal)
        let expectedLabel: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MMM d"
            return f.string(from: day2)
        }()
        XCTAssertEqual(label, expectedLabel)
        XCTAssertEqual(PackSavingsLedger.formatTokenCount(1235), "1,235")

        try? FileManager.default.removeItem(at: dir)
    }

    func testRecordUsesSourceWholeFileBaseline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)

        let surgicalOnly = PackResult(
            packet: "# x",
            requestedMode: .surgical,
            deliveredMode: .surgical,
            deliveredTokens: 100,
            surgicalTokens: 100,
            fullBaselineTokens: nil,
            sourceWholeFileTokens: 400
        )
        try ledger.record(from: surgicalOnly, task: "t", repo: "/r", budget: 12000)
        let entries = try ledger.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sourceWholeFileTokens, 400)
        XCTAssertEqual(entries[0].tokensSaved, 300)
        XCTAssertEqual(entries[0].deliveredTokens, 100)

        try? FileManager.default.removeItem(at: dir)
    }

    func testNegativeTokensSavedRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-ledger-neg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)

        let regression = PackResult(
            packet: "# big",
            requestedMode: .auto,
            deliveredMode: .surgical,
            deliveredTokens: 2593,
            surgicalTokens: 2593,
            fullBaselineTokens: 3000,
            sourceWholeFileTokens: 2046
        )
        XCTAssertEqual(regression.tokensSavedVersusSourceFiles, 2046 - 2593)
        try ledger.record(from: regression, task: "t", repo: "/r", budget: 3000)
        let entries = try ledger.loadEntries()
        XCTAssertEqual(entries[0].tokensSaved, -547)
        let line = PackSavingsLedger.formatSavingsLine(saved: -547, sourceWholeFileTokens: 2046)
        XCTAssertTrue(line.contains("-547"))

        try? FileManager.default.removeItem(at: dir)
    }

    func testActionRecordBaselineTokensDecodeTolerant() throws {
        let json = """
        {"id":1,"prompt":"cckit find-symbol X","toolName":"find-symbol","type":"cli","tokensUsed":10,"baselineTokens":99,"durationMs":1,"status":"completed","timestamp":"2026-08-12T12:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ActionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.tokensUsed, 10)
        XCTAssertEqual(record.sourceWholeFileTokens, 0)
    }

    func testTokensAvoidedVersusSourceFileIsSigned() {
        let win = ActionRecord(
            prompt: "cckit outline F",
            toolName: "outline",
            tokensUsed: 100,
            sourceWholeFileTokens: 400
        )
        XCTAssertEqual(win.tokensAvoidedVersusSourceFile, 300)

        let loss = ActionRecord(
            prompt: "cckit outline F",
            toolName: "outline",
            tokensUsed: 500,
            sourceWholeFileTokens: 400
        )
        XCTAssertEqual(loss.tokensAvoidedVersusSourceFile, -100)
    }

    func testEvictedPackRowsFoldIntoMonthlyRollups() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-rollup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)
        let now = Date()
        func entry(ageDays: Double, delivered: Int, saved: Int) -> PackSavingsEntry {
            PackSavingsEntry(
                timestamp: now.addingTimeInterval(-ageDays * 86_400),
                task: "t",
                repo: "/r",
                requestedMode: "auto",
                deliveredMode: "surgical",
                deliveredTokens: delivered,
                sourceWholeFileTokens: delivered + saved,
                tokensSaved: saved,
                budget: 100
            )
        }
        // Two evicted rows land in the same month bucket; one row stays live.
        try ledger.append(entry(ageDays: 8, delivered: 100, saved: 50), now: now)
        try ledger.append(entry(ageDays: 9, delivered: 200, saved: 80), now: now)
        try ledger.append(entry(ageDays: 1, delivered: 10, saved: 5), now: now)

        let later = now.addingTimeInterval(25 * 3600)
        let remaining = try ledger.loadEntries(now: later)
        XCTAssertEqual(remaining.count, 1, "evicted rows leave the daily ledger")

        let rollups = LedgerRollups.loadSavings(cckitDir: dir)
        XCTAssertEqual(rollups.count, 1)
        let month = rollups[0]
        let expectedKey = LedgerRollups.monthKey(for: now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(month.monthKey, expectedKey)
        XCTAssertEqual(month.packs, 2)
        XCTAssertEqual(month.deliveredTokens, 300)
        XCTAssertEqual(month.sourceWholeFileTokens, 430)
        XCTAssertEqual(month.tokensSaved, 130)

        // Folding again must not happen — pruned rows are gone, so totals stay stable.
        let muchLater = later.addingTimeInterval(25 * 3600)
        _ = try ledger.loadEntries(now: muchLater)
        let rolledAgain = LedgerRollups.loadSavings(cckitDir: dir)
        XCTAssertEqual(rolledOnlyTotals(rolledAgain), rolledOnlyTotals(rollups))
    }

    private func rolledOnlyTotals(_ rollups: [MonthlySavingsRollup]) -> Int {
        rollups.map(\.tokensSaved).reduce(0, +)
    }

    func testMonthlyToolRollupAggregatesByTool() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-toolrollup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = Date().addingTimeInterval(-9 * 86_400)
        let records = [
            ActionRecord(id: 1, prompt: "cckit symbol", toolName: "symbol", type: "mcp",
                         tokensUsed: 1200, sourceWholeFileTokens: 3000, durationMs: 10,
                         status: "completed", timestamp: old),
            ActionRecord(id: 2, prompt: "cckit symbol", toolName: "symbol", type: "mcp",
                         tokensUsed: 800, sourceWholeFileTokens: 2000, durationMs: 12,
                         status: "completed", timestamp: old),
        ]
        let url = dir.appendingPathComponent(LedgerRollups.toolRollupFileName)
        try LedgerRollups.foldActions(records, into: url)
        let rollups = LedgerRollups.loadTools(cckitDir: dir)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].tool, "symbol")
        XCTAssertEqual(rollups[0].calls, 2)
        XCTAssertEqual(rollups[0].tokensUsed, 2000)

        // Second fold of the same month merges without duplicating rows.
        try LedgerRollups.foldActions([records[0]], into: url)
        let merged = LedgerRollups.loadTools(cckitDir: dir)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].calls, 3)
    }

    func testPackStatsPrunesOlderThanSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-ledger-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)
        let now = Date()
        func entry(ageDays: Double, task: String) -> PackSavingsEntry {
            PackSavingsEntry(
                timestamp: now.addingTimeInterval(-ageDays * 86_400),
                task: task,
                repo: "/r",
                requestedMode: "auto",
                deliveredMode: "surgical",
                deliveredTokens: 10,
                sourceWholeFileTokens: 20,
                tokensSaved: 10,
                budget: 100
            )
        }
        // First append: prune due (no stamp) — old row written then immediately eligible for prune
        // on a later due check. Seed both, then force a second prune 25h later.
        try ledger.append(entry(ageDays: 8, task: "old"), now: now)
        // 5 days so it remains inside the 7-day window after a 25h delay.
        try ledger.append(entry(ageDays: 5, task: "kept"), now: now)
        // Stamp is fresh — old row still on disk until prune is due again.
        let mid = try ledger.loadEntries(now: now)
        XCTAssertEqual(Set(mid.map(\.task)), Set(["old", "kept"]))

        let later = now.addingTimeInterval(25 * 3600)
        let remaining = try ledger.loadEntries(now: later)
        XCTAssertEqual(remaining.map(\.task), ["kept"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testActionHistoryPrunesOlderThanSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-hist-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("action_history.jsonl")
        let store = ActionHistoryStore(fileURL: file)
        let now = Date()
        try store.append(ActionRecord(
            id: 1,
            prompt: "old",
            toolName: "map",
            type: "cli",
            timestamp: now.addingTimeInterval(-8 * 86_400)
        ), now: now)
        try store.append(ActionRecord(
            id: 2,
            prompt: "kept",
            toolName: "map",
            type: "cli",
            timestamp: now.addingTimeInterval(-5 * 86_400)
        ), now: now)
        let mid = try store.loadEntries(now: now)
        XCTAssertEqual(Set(mid.map(\.prompt)), Set(["old", "kept"]))

        let later = now.addingTimeInterval(25 * 3600)
        let remaining = try store.loadEntries(now: later)
        XCTAssertEqual(remaining.map(\.prompt), ["kept"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testDailyPruneRunsAtMostOncePerDay() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-daily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)
        let now = Date()

        func entry(ageDays: Double, task: String) -> PackSavingsEntry {
            PackSavingsEntry(
                timestamp: now.addingTimeInterval(-ageDays * 86_400),
                task: task,
                repo: "/r",
                requestedMode: "auto",
                deliveredMode: "surgical",
                deliveredTokens: 10,
                sourceWholeFileTokens: 20,
                tokensSaved: 10,
                budget: 100
            )
        }

        try ledger.append(entry(ageDays: 8, task: "old"), now: now)
        try ledger.append(entry(ageDays: 1, task: "kept"), now: now)

        // Same-day second append: stamp fresh → append-only, old row still present.
        let sameDay = try ledger.loadEntries(now: now.addingTimeInterval(3600))
        XCTAssertEqual(Set(sameDay.map(\.task)), Set(["old", "kept"]))
        XCTAssertFalse(JSONLRetention.isPruneDue(cckitDir: dir, now: now.addingTimeInterval(3600)))

        // 25 hours later: prune drops the >7-day row.
        let nextDay = now.addingTimeInterval(25 * 3600)
        XCTAssertTrue(JSONLRetention.isPruneDue(cckitDir: dir, now: nextDay))
        let pruned = try ledger.loadEntries(now: nextDay)
        XCTAssertEqual(pruned.map(\.task), ["kept"])
        XCTAssertFalse(JSONLRetention.isPruneDue(cckitDir: dir, now: nextDay))

        try? FileManager.default.removeItem(at: dir)
    }

    func testLoadEntriesPrunesWithoutAppend() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-load-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)
        let now = Date()

        try ledger.append(PackSavingsEntry(
            timestamp: now.addingTimeInterval(-8 * 86_400),
            task: "old",
            repo: "/r",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 10,
            sourceWholeFileTokens: 20,
            tokensSaved: 10,
            budget: 100
        ), now: now)
        try ledger.append(PackSavingsEntry(
            timestamp: now.addingTimeInterval(-1 * 86_400),
            task: "kept",
            repo: "/r",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 10,
            sourceWholeFileTokens: 20,
            tokensSaved: 10,
            budget: 100
        ), now: now)

        let later = now.addingTimeInterval(25 * 3600)
        let remaining = try ledger.loadEntries(now: later)
        XCTAssertEqual(remaining.map(\.task), ["kept"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testWallClockCutoffIgnoresNewestRow() throws {
        let now = Date()
        let rows = [
            ("old", now.addingTimeInterval(-8 * 86_400)),
            ("future", now.addingTimeInterval(2 * 86_400)),
        ]
        struct Row: Equatable {
            var timestamp: Date
            var name: String
        }
        let entries = rows.map { Row(timestamp: $0.1, name: $0.0) }
        let pruned = JSONLRetention.prune(entries, now: now, timestamp: \.timestamp)
        // Future row is retained (>= cutoff); old is not — newest-row clock no longer extends window.
        XCTAssertEqual(pruned.map(\.name), ["future"])
    }

    func testJSONLRetentionLoadRewritePruneAreShared() throws {
        struct Row: Codable, Equatable {
            var timestamp: Date
            var name: String
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rows.jsonl")
        let now = Date()
        let rows = [
            Row(timestamp: now.addingTimeInterval(-8 * 86_400), name: "old"),
            Row(timestamp: now.addingTimeInterval(-1 * 86_400), name: "kept"),
        ]
        try JSONLRetention.rewrite(rows, to: file)
        let loaded = try JSONLRetention.load(Row.self, from: file)
        XCTAssertEqual(loaded.map(\.name), ["old", "kept"])
        let pruned = JSONLRetention.prune(loaded, now: now, timestamp: \.timestamp)
        XCTAssertEqual(pruned.map(\.name), ["kept"])
        try? FileManager.default.removeItem(at: dir)
    }

    func testAppendLineDoesNotRewriteWhenStampFresh() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack_savings.jsonl")
        let ledger = PackSavingsLedger(fileURL: file)
        let now = Date()

        try ledger.append(PackSavingsEntry(
            timestamp: now,
            task: "a",
            repo: "/r",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 10,
            sourceWholeFileTokens: 20,
            tokensSaved: 10,
            budget: 100
        ), now: now)

        let sizeAfterFirst = try Data(contentsOf: file).count
        try ledger.append(PackSavingsEntry(
            timestamp: now,
            task: "b",
            repo: "/r",
            requestedMode: "auto",
            deliveredMode: "surgical",
            deliveredTokens: 10,
            sourceWholeFileTokens: 20,
            tokensSaved: 10,
            budget: 100
        ), now: now.addingTimeInterval(60))

        let sizeAfterSecond = try Data(contentsOf: file).count
        XCTAssertGreaterThan(sizeAfterSecond, sizeAfterFirst)
        let entries = try ledger.loadEntries(now: now.addingTimeInterval(60))
        XCTAssertEqual(entries.map(\.task), ["a", "b"])
        try? FileManager.default.removeItem(at: dir)
    }
}
