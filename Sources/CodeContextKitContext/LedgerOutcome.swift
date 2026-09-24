import Foundation
import CodeContextKitCore

/// Stable outcome tokens for action-history rows and monthly tool rollups.
///
/// Monthly fold used to keep only `calls`/`tokensUsed`, so a "why is pack empty"
/// question could not survive the 7-day eviction. Reasons are snake_case and
/// additive — old rollup files without the fields decode as zeros.
public enum LedgerOutcome: Sendable {
    public static let productive = "productive"
    public static let zeroPrimary = "zero_primary"
    public static let preview = "preview"
    public static let budgetTruncated = "budget_truncated"
    public static let lexicalEmpty = "lexical_empty"
    public static let semanticUnavailable = "semantic_unavailable"
    public static let leaseHeld = "lease_held"
    public static let noIndex = "no_index"
    public static let embedder = "embedder"
    public static let readGate = "read_gate"
    public static let badArgs = "bad_args"
    public static let failed = "failed"
    public static let skipped = "skipped"
    public static let completed = "completed"

    public static func isFailure(_ reason: String) -> Bool {
        switch reason {
        case failed, leaseHeld, noIndex, embedder, readGate, badArgs, skipped:
            true
        default:
            false
        }
    }

    /// Completed pack that delivered no confident primaries (not an infra reject).
    public static func isZeroPrimary(_ reason: String) -> Bool {
        switch reason {
        case zeroPrimary, budgetTruncated, lexicalEmpty, semanticUnavailable:
            true
        default:
            false
        }
    }

    public static func classifyFailure(_ response: String?) -> String {
        let text = response ?? ""
        let lower = text.lowercased()
        if lower.contains("already in use") || lower.contains("stable lease") {
            return leaseHeld
        }
        if lower.contains("index not found") {
            return noIndex
        }
        if lower.contains("minilm") || lower.contains("embedder") || lower.contains("semantic store") {
            return embedder
        }
        if lower.contains("truncated arena") || lower.contains("breach") || lower.contains("unserviceable") {
            return readGate
        }
        if lower.contains("not both") || lower.contains("cannot be combined") || lower.contains("bad_mode") {
            return badArgs
        }
        if lower.contains("skipped") {
            return skipped
        }
        return failed
    }

    public static func packCompleted(
        isPreview: Bool,
        primaryCount: Int,
        wasBudgetTruncated: Bool,
        wasLexicalEmpty: Bool,
        wasSemanticUnavailable: Bool
    ) -> String {
        if isPreview { return preview }
        if wasBudgetTruncated { return budgetTruncated }
        if wasLexicalEmpty { return lexicalEmpty }
        if wasSemanticUnavailable { return semanticUnavailable }
        if primaryCount == 0 { return zeroPrimary }
        return productive
    }

    /// Prefer a stamped `outcomeReason`; otherwise infer from status / primaryCount /
    /// prompt flags / a same-window savings row (legacy rows from before stamping).
    public static func reason(
        for record: ActionRecord,
        savings: [PackSavingsEntry] = []
    ) -> String {
        if let stamped = record.outcomeReason, !stamped.isEmpty {
            return stamped
        }
        let status = record.status.lowercased()
        if status == "failed" {
            return classifyFailure(record.response)
        }
        if status == "skipped" {
            return skipped
        }
        let tool = record.toolName ?? ""
        let prompt = record.prompt
        if tool == "pack" || prompt.contains(" cckit pack") || prompt.hasPrefix("cckit pack")
            || prompt.contains(" pack --")
        {
            if prompt.contains("--preview") {
                return preview
            }
            if let count = record.primaryCount {
                return packCompleted(
                    isPreview: false,
                    primaryCount: count,
                    wasBudgetTruncated: false,
                    wasLexicalEmpty: false,
                    wasSemanticUnavailable: false
                )
            }
            if matchingSavings(record, in: savings) != nil {
                return productive
            }
            return zeroPrimary
        }
        return completed
    }

    public static func matchingSavings(
        _ record: ActionRecord,
        in savings: [PackSavingsEntry]
    ) -> PackSavingsEntry? {
        savings.first { entry in
            abs(entry.timestamp.timeIntervalSince(record.timestamp)) <= 5
                && (entry.task.isEmpty || record.prompt.contains(entry.task))
        }
    }
}
