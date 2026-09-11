import CodeContextKitCore

/// Last-resort recovery for failures that escaped the normal breach marker.
/// The ledger is append-only and survives `index --clean`, so it is the one
/// durable place to identify an auto-refresh loop across process launches.
public enum IndexFailureEscalation {
    public static let threshold = 3

    /// `records` must be newest first (`ActionOrchestrator.getRecentActions`'s
    /// contract). Any completed, skipped, differently-worded, or non-index
    /// terminal index row breaks the streak.
    public static func repeatedReason(
        in records: [ActionRecord],
        threshold: Int = threshold
    ) -> String? {
        guard threshold > 0 else { return nil }
        var reason: String?
        var count = 0
        for record in records where record.toolName == "index" {
            guard record.status == "failed",
                  let response = record.response?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !response.isEmpty else {
                break
            }
            if let reason, reason != response { break }
            reason = response
            count += 1
            if count >= threshold { return reason }
        }
        return nil
    }
}
