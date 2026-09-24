import Foundation

/// Timestamped JSONL record of every index run's decision and outcome.
///
/// `refresh.log` captured detached-shim stdout only, carried no timestamps, and
/// missed plain `cckit index .` runs entirely — so a 20-minute full rebuild
/// could not be explained after the fact. This log is written on every run
/// (CLI, shim-spawned, server-triggered), so a `DeltaDecision` that names its
/// `refusedBy` predicate and the resulting `WaxCompact` tally survive
/// regardless of trigger source or whether stdout is a TTY.
///
/// Format (one JSON object per line, append-only):
///   {"at":"2026-09-23T...Z","event":"DeltaDecision","payload":{...}}
///   {"at":"...","event":"WaxCompact","payload":{...}}
///   {"at":"...","event":"IndexFailure","payload":{"reason":"..."}}
public enum IndexRunLog {
    public static let fileName = "index-runs.jsonl"

    /// Cap so a storm of runs cannot grow the file without bound. Rotated by
    /// truncation before an append, mirroring the shim's refresh.log handling.
    public static let maxBytes = 2 * 1024 * 1024

    public static func record(event: String, payload: [String: Any], cckitDir: String = ".cckit") {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        append(data, cckitDir: cckitDir)
    }

    /// The eligibility verdict for one semantic run, with `refusedBy` present
    /// whenever the run replaced the arena.
    public static func recordDeltaDecision(
        _ decision: WaxDeltaPolicy.Decision,
        cckitDir: String = ".cckit"
    ) {
        record(event: "DeltaDecision", payload: decision.payload, cckitDir: cckitDir)
    }

    public static func recordWaxCompact(_ payload: [String: Any], cckitDir: String = ".cckit") {
        record(event: "WaxCompact", payload: payload, cckitDir: cckitDir)
    }

    public static func recordFailure(
        reason: String,
        command: String? = nil,
        cckitDir: String = ".cckit"
    ) {
        var payload: [String: Any] = ["reason": reason]
        if let command, !command.isEmpty {
            payload["command"] = command
        }
        record(event: "IndexFailure", payload: payload, cckitDir: cckitDir)
    }

    public static func recordSkipped(
        reason: String,
        command: String? = nil,
        cckitDir: String = ".cckit"
    ) {
        var payload: [String: Any] = ["reason": reason]
        if let command, !command.isEmpty {
            payload["command"] = command
        }
        record(event: "IndexSkipped", payload: payload, cckitDir: cckitDir)
    }

    private static func append(_ data: Data, cckitDir: String) {
        let path = (cckitDir as NSString).appendingPathComponent(fileName)
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > maxBytes {
            try? Data().write(to: url, options: .atomic)
        }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}
