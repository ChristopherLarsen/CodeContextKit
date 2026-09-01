import Foundation
import CodeContextKitCore
import CodeContextKitRetrieval

/// Shared 7-day cap and JSONL I/O for `.cckit` ledgers so they cannot grow unbounded.
///
/// Prune runs at most once per calendar day of wall-clock time (stamp file), not on
/// every append. Cutoff is strictly `now - 7 days` — no newest-row clock skew.
public enum JSONLRetention: Sendable {
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let pruneInterval: TimeInterval = 24 * 60 * 60
    public static let stampFileName = "jsonl_retention_stamp"
    /// Environment override for the retention window (days). Rollups keep the
    /// evicted aggregates, so raising this is optional, not required, for history.
    public static let keepDaysEnv = "CCKIT_LEDGER_KEEP_DAYS"

    public static func effectiveMaxAge(now: Date = Date()) -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment[keepDaysEnv],
           let days = Int(raw), days >= 1 {
            return TimeInterval(days) * 24 * 60 * 60
        }
        return maxAge
    }

    public static func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-effectiveMaxAge(now: now))
    }

    public static func isRetained(_ timestamp: Date, now: Date = Date()) -> Bool {
        timestamp >= cutoff(now: now)
    }

    /// Keep rows within `maxAge` of wall-clock `now`.
    public static func prune<T>(
        _ entries: [T],
        now: Date = Date(),
        timestamp: (T) -> Date
    ) -> [T] {
        entries.filter { isRetained(timestamp($0), now: now) }
    }

    public static func load<T: Decodable>(_ type: T.Type, from fileURL: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [T] = []
        var malformed = 0
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            do {
                entries.append(try decoder.decode(T.self, from: Data(line.utf8)))
            } catch {
                malformed += 1
            }
        }
        // A torn line (crash mid-append) must degrade the ledger, not brick
        // every tool that touches it — search/pack append to these files on
        // every call and used to exit 1 the moment one line was unreadable.
        if malformed > 0 {
            FileHandle.standardError.write(Data(
                "[cckit] skipped \(malformed) malformed ledger line(s) in \(fileURL.lastPathComponent)\n".utf8
            ))
        }
        return entries
    }

    public static func rewrite<T: Encodable>(_ entries: [T], to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(contentsOf: "\n".utf8)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    /// Append one JSONL line without rewriting the file.
    public static func appendLine<T: Encodable>(_ entry: T, to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public static func stampURL(cckitDir: URL) -> URL {
        cckitDir.appendingPathComponent(stampFileName)
    }

    /// True when the stamp is missing or at least `pruneInterval` old.
    public static func isPruneDue(cckitDir: URL, now: Date = Date()) -> Bool {
        let stamp = stampURL(cckitDir: cckitDir)
        guard FileManager.default.fileExists(atPath: stamp.path),
              let text = try? String(contentsOf: stamp, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let last = ISO8601DateFormatter().date(from: text)
        else {
            return true
        }
        return now.timeIntervalSince(last) >= pruneInterval
    }

    public static func writeStamp(cckitDir: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: cckitDir, withIntermediateDirectories: true)
        let text = ISO8601DateFormatter().string(from: now)
        try text.write(to: stampURL(cckitDir: cckitDir), atomically: true, encoding: .utf8)
    }

    /// If prune is due, fold evicted rows into monthly rollups, rewrite both known
    /// JSONL ledgers under `cckitDir`, and refresh the stamp.
    /// Returns whether a prune ran.
    @discardableResult
    public static func ensurePrunedIfDue(cckitDir: URL, now: Date = Date()) throws -> Bool {
        guard isPruneDue(cckitDir: cckitDir, now: now) else { return false }

        // The prune is read-modify-REWRITE: a concurrent process appending
        // between the read and the rewrite loses its row. Every cckit process
        // already honors the repo refresh lock, so hold it for the rewrite;
        // when a long index run holds it, pruning waits for a later call.
        guard let lock = RefreshLock.tryAcquire(
            lockPath: cckitDir.appendingPathComponent("refresh.lock").path
        ) else {
            return false
        }
        defer { lock.release() }

        let packURL = cckitDir.appendingPathComponent(PackSavingsLedger.fileName)
        let historyURL = cckitDir.appendingPathComponent(ActionHistoryStore.fileName)

        if FileManager.default.fileExists(atPath: packURL.path) {
            let entries = try load(PackSavingsEntry.self, from: packURL)
            let evicted = entries.filter { !isRetained($0.timestamp, now: now) }
            if !evicted.isEmpty {
                try LedgerRollups.foldSavings(
                    evicted,
                    into: cckitDir.appendingPathComponent(LedgerRollups.savingsRollupFileName)
                )
            }
            try rewrite(prune(entries, now: now, timestamp: \.timestamp), to: packURL)
        }
        if FileManager.default.fileExists(atPath: historyURL.path) {
            let entries = try load(ActionRecord.self, from: historyURL)
            let evicted = entries.filter { !isRetained($0.timestamp, now: now) }
            if !evicted.isEmpty {
                try LedgerRollups.foldActions(
                    evicted,
                    into: cckitDir.appendingPathComponent(LedgerRollups.toolRollupFileName)
                )
            }
            try rewrite(prune(entries, now: now, timestamp: \.timestamp), to: historyURL)
        }
        try writeStamp(cckitDir: cckitDir, now: now)
        return true
    }
}

/// One month of rolled-up pack savings (rows evicted by the retention window).
public struct MonthlySavingsRollup: Codable, Sendable, Equatable {
    /// UTC calendar month, `YYYY-MM`.
    public var monthKey: String
    public var packs: Int
    public var deliveredTokens: Int
    public var sourceWholeFileTokens: Int
    public var tokensSaved: Int

    public init(monthKey: String, packs: Int, deliveredTokens: Int, sourceWholeFileTokens: Int, tokensSaved: Int) {
        self.monthKey = monthKey
        self.packs = packs
        self.deliveredTokens = deliveredTokens
        self.sourceWholeFileTokens = sourceWholeFileTokens
        self.tokensSaved = tokensSaved
    }
}

/// One month of rolled-up tool usage, keyed by tool.
public struct MonthlyToolRollup: Codable, Sendable, Equatable {
    public var monthKey: String
    public var tool: String
    public var calls: Int
    public var tokensUsed: Int

    public init(monthKey: String, tool: String, calls: Int, tokensUsed: Int) {
        self.monthKey = monthKey
        self.tool = tool
        self.calls = calls
        self.tokensUsed = tokensUsed
    }
}

/// Monthly aggregates that survive 7-day JSONL pruning so pack-stats can report
/// lifetime and per-month savings, not just the last week.
public enum LedgerRollups: Sendable {
    public static let savingsRollupFileName = "pack_savings_monthly.jsonl"
    public static let toolRollupFileName = "tool_usage_monthly.jsonl"

    /// UTC calendar month key, `YYYY-MM`.
    public static func monthKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// Merge evicted pack rows into the monthly rollup file (summing per month).
    public static func foldSavings(_ evicted: [PackSavingsEntry], into fileURL: URL) throws {
        guard !evicted.isEmpty else { return }
        var existing: [MonthlySavingsRollup] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existing = try JSONLRetention.load(MonthlySavingsRollup.self, from: fileURL)
        }
        var byMonth: [String: MonthlySavingsRollup] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.monthKey, $0) }
        )
        for entry in evicted {
            let key = monthKey(for: entry.timestamp)
            var rollup = byMonth[key] ?? MonthlySavingsRollup(
                monthKey: key, packs: 0, deliveredTokens: 0, sourceWholeFileTokens: 0, tokensSaved: 0
            )
            rollup.packs += 1
            rollup.deliveredTokens += entry.deliveredTokens
            rollup.sourceWholeFileTokens += entry.sourceWholeFileTokens
            rollup.tokensSaved += entry.tokensSaved
            byMonth[key] = rollup
        }
        try JSONLRetention.rewrite(byMonth.values.sorted { $0.monthKey < $1.monthKey }, to: fileURL)
    }

    /// Merge evicted action rows into the monthly tool-usage rollup file.
    public static func foldActions(_ evicted: [ActionRecord], into fileURL: URL) throws {
        guard !evicted.isEmpty else { return }
        var existing: [MonthlyToolRollup] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existing = try JSONLRetention.load(MonthlyToolRollup.self, from: fileURL)
        }
        func keyFor(_ record: ActionRecord) -> String {
            "\(monthKey(for: record.timestamp))\u{1f}\(record.toolName ?? record.type)"
        }
        var byKey: [String: MonthlyToolRollup] = Dictionary(
            uniqueKeysWithValues: existing.map { ("\( $0.monthKey )\u{1f}\($0.tool)", $0) }
        )
        for record in evicted {
            let key = keyFor(record)
            let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            let month = parts.first ?? ""
            let tool = parts.dropFirst().first ?? record.toolName ?? record.type
            var rollup = byKey[key] ?? MonthlyToolRollup(monthKey: month, tool: tool, calls: 0, tokensUsed: 0)
            rollup.calls += 1
            rollup.tokensUsed += record.tokensUsed
            byKey[key] = rollup
        }
        try JSONLRetention.rewrite(
            byKey.values.sorted { ($0.monthKey, $0.tool) < ($1.monthKey, $1.tool) },
            to: fileURL
        )
    }

    public static func loadSavings(cckitDir: URL) -> [MonthlySavingsRollup] {
        let url = cckitDir.appendingPathComponent(savingsRollupFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return (try? JSONLRetention.load(MonthlySavingsRollup.self, from: url)) ?? []
    }

    public static func loadTools(cckitDir: URL) -> [MonthlyToolRollup] {
        let url = cckitDir.appendingPathComponent(toolRollupFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return (try? JSONLRetention.load(MonthlyToolRollup.self, from: url)) ?? []
    }
}

/// One pack event recorded for local token-savings evaluation.
public struct PackSavingsEntry: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var task: String
    public var repo: String
    public var requestedMode: String
    public var deliveredMode: String
    public var deliveredTokens: Int
    public var surgicalTokens: Int?
    /// Dual-pack full-mode size when available (comparison only; not the savings baseline).
    public var fullBaselineTokens: Int?
    /// Whole-file token sum for primary files in the packet (honest Read baseline).
    public var sourceWholeFileTokens: Int
    /// `sourceWholeFileTokens - deliveredTokens` (may be negative when the packet lost to raw files).
    public var tokensSaved: Int
    public var budget: Int

    public init(
        timestamp: Date = Date(),
        task: String,
        repo: String,
        requestedMode: String,
        deliveredMode: String,
        deliveredTokens: Int,
        surgicalTokens: Int? = nil,
        fullBaselineTokens: Int? = nil,
        sourceWholeFileTokens: Int,
        tokensSaved: Int,
        budget: Int
    ) {
        self.timestamp = timestamp
        self.task = task
        self.repo = repo
        self.requestedMode = requestedMode
        self.deliveredMode = deliveredMode
        self.deliveredTokens = deliveredTokens
        self.surgicalTokens = surgicalTokens
        self.fullBaselineTokens = fullBaselineTokens
        self.sourceWholeFileTokens = sourceWholeFileTokens
        self.tokensSaved = tokensSaved
        self.budget = budget
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, task, repo, requestedMode, deliveredMode
        case deliveredTokens, surgicalTokens, fullBaselineTokens
        case sourceWholeFileTokens, tokensSaved, budget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        task = try c.decode(String.self, forKey: .task)
        repo = try c.decode(String.self, forKey: .repo)
        requestedMode = try c.decode(String.self, forKey: .requestedMode)
        deliveredMode = try c.decode(String.self, forKey: .deliveredMode)
        deliveredTokens = try c.decode(Int.self, forKey: .deliveredTokens)
        surgicalTokens = try c.decodeIfPresent(Int.self, forKey: .surgicalTokens)
        fullBaselineTokens = try c.decodeIfPresent(Int.self, forKey: .fullBaselineTokens)
        // Older ledger rows only had tokensSaved vs dual-pack full baseline.
        sourceWholeFileTokens = try c.decodeIfPresent(Int.self, forKey: .sourceWholeFileTokens)
            ?? (try c.decodeIfPresent(Int.self, forKey: .fullBaselineTokens) ?? 0)
        tokensSaved = try c.decode(Int.self, forKey: .tokensSaved)
        budget = try c.decode(Int.self, forKey: .budget)
    }
}

/// JSONL ledger under `.cckit/pack_savings.jsonl` (7-day retention, prune once/day).
public struct PackSavingsLedger: Sendable {
    public static let fileName = "pack_savings.jsonl"

    public let fileURL: URL
    public var cckitDir: URL { fileURL.deletingLastPathComponent() }

    public init(repoRoot: String = ".") {
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
        self.fileURL = root.appendingPathComponent(".cckit").appendingPathComponent(Self.fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Records every pack that has a whole-file source baseline.
    public func record(from result: PackResult, task: String, repo: String, budget: Int) throws {
        guard result.sourceWholeFileTokens > 0 || result.deliveredTokens > 0 else { return }
        let entry = PackSavingsEntry(
            task: task,
            repo: repo,
            requestedMode: result.requestedMode.rawValue,
            deliveredMode: result.deliveredMode.rawValue,
            deliveredTokens: result.deliveredTokens,
            surgicalTokens: result.surgicalTokens,
            fullBaselineTokens: result.fullBaselineTokens,
            sourceWholeFileTokens: result.sourceWholeFileTokens,
            tokensSaved: result.tokensSavedVersusSourceFiles,
            budget: budget
        )
        try append(entry)
    }

    public func append(_ entry: PackSavingsEntry, now: Date = Date()) throws {
        try JSONLRetention.ensurePrunedIfDue(cckitDir: cckitDir, now: now)
        try JSONLRetention.appendLine(entry, to: fileURL)
    }

    public func loadEntries(now: Date = Date()) throws -> [PackSavingsEntry] {
        try JSONLRetention.ensurePrunedIfDue(cckitDir: cckitDir, now: now)
        return try JSONLRetention.load(PackSavingsEntry.self, from: fileURL)
    }

    /// Savings summed by calendar day in the given time zone (default: local).
    public func savingsByDay(        timeZone: TimeZone = .current,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [(day: Date, tokensSaved: Int, tokensDelivered: Int, sourceWholeFileTokens: Int, packs: Int)] {
        var cal = calendar
        cal.timeZone = timeZone

        var buckets: [Date: (saved: Int, delivered: Int, source: Int, packs: Int)] = [:]
        for entry in try loadEntries(now: now) {
            let day = cal.startOfDay(for: entry.timestamp)
            let prior = buckets[day] ?? (0, 0, 0, 0)
            buckets[day] = (
                prior.saved + entry.tokensSaved,
                prior.delivered + entry.deliveredTokens,
                prior.source + entry.sourceWholeFileTokens,
                prior.packs + 1
            )
        }

        return buckets.keys.sorted().map { day in
            let value = buckets[day]!
            return (day, value.saved, value.delivered, value.source, value.packs)
        }
    }

    /// Fraction of source-file usage avoided: `saved / sourceWholeFileTokens`.
    public static func savingsPercentOfUsage(saved: Int, sourceWholeFileTokens: Int) -> Double? {
        guard sourceWholeFileTokens > 0 else { return nil }
        return Double(saved) / Double(sourceWholeFileTokens) * 100.0
    }

    public static func formatDayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: day)
    }

    public static func formatTokenCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func formatSavingsLine(saved: Int, sourceWholeFileTokens: Int, packs: Int? = nil) -> String {
        let savedText = "\(formatTokenCount(saved)) tokens saved vs whole files"
        let pctText: String
        if let pct = savingsPercentOfUsage(saved: saved, sourceWholeFileTokens: sourceWholeFileTokens) {
            pctText = String(format: "%.1f%% of source", pct)
        } else {
            pctText = "n/a % of source"
        }
        if let packs {
            return "\(savedText) · \(pctText) (\(packs) pack\(packs == 1 ? "" : "s"))"
        }
        return "\(savedText) · \(pctText)"
    }
}

/// Action/telemetry history under `.cckit/action_history.jsonl` (7-day retention, prune once/day).
/// Survives `cckit index --clean` (which only deletes index.sqlite + repo.wax).
public struct ActionHistoryStore: Sendable {
    public static let fileName = "action_history.jsonl"

    public let fileURL: URL
    public var cckitDir: URL { fileURL.deletingLastPathComponent() }

    public init(repoRoot: String = ".") {
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
        self.fileURL = root.appendingPathComponent(".cckit").appendingPathComponent(Self.fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func append(_ record: ActionRecord, now: Date = Date()) throws {
        try JSONLRetention.ensurePrunedIfDue(cckitDir: cckitDir, now: now)
        try JSONLRetention.appendLine(record, to: fileURL)
    }

    public func loadEntries(now: Date = Date()) throws -> [ActionRecord] {
        try JSONLRetention.ensurePrunedIfDue(cckitDir: cckitDir, now: now)
        return try JSONLRetention.load(ActionRecord.self, from: fileURL)
    }

    /// Recent actions, newest first.
    public func recent(limit: Int = 50, now: Date = Date()) throws -> [ActionRecord] {
        Array(try loadEntries(now: now).suffix(limit).reversed())
    }

    /// Replace the matching id's record (used to finish pending web actions).
    public func upsert(_ record: ActionRecord, now: Date = Date()) throws {
        try JSONLRetention.ensurePrunedIfDue(cckitDir: cckitDir, now: now)
        var entries = try JSONLRetention.load(ActionRecord.self, from: fileURL)
        if let id = record.id, let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = record
        } else {
            entries.append(record)
        }
        // Upsert must rewrite (in-place replace); still only prune when due.
        try JSONLRetention.rewrite(entries, to: fileURL)
    }

    /// Next monotonic id for pending/completed rows.
    public func nextId(now: Date = Date()) throws -> Int64 {
        let maxId = try loadEntries(now: now).compactMap(\.id).max() ?? 0
        return maxId + 1
    }
}

/// Aggregate of the MCP shim's delivery-dedup ledger (`dedup_savings.jsonl`):
/// tokens avoided by stubbing unchanged re-deliveries (symbol/gather/outline).
public struct DedupSavingsSummary: Sendable {
    public var calls: Int = 0
    public var tokensSaved: Int = 0
    public var byTool: [String: (calls: Int, tokensSaved: Int)] = [:]

    public init() {}
}

extension PackSavingsLedger {
    /// Reads `.cckit/dedup_savings.jsonl` written by the shim's session dedup.
    public static func readDedupSavings(cckitDir: URL) -> DedupSavingsSummary {
        let url = cckitDir.appendingPathComponent("dedup_savings.jsonl")
        var summary = DedupSavingsSummary()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return summary
        }
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let saved = row["savedTokens"] as? Int
            else { continue }
            let tool = (row["tool"] as? String) ?? "unknown"
            summary.calls += 1
            summary.tokensSaved += saved
            let prior = summary.byTool[tool] ?? (0, 0)
            summary.byTool[tool] = (prior.calls + 1, prior.tokensSaved + saved)
        }
        return summary
    }
}
