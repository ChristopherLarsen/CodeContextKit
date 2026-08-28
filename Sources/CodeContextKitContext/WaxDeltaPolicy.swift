import Foundation

/// Incremental (delta) indexing policy for the derived Wax arena.
///
/// Wax (pinned 3405b8c) returns no frame IDs from `Memory.save` and exposes no
/// batch-delete transaction; its only delete is per-frame, and the harness
/// measured ~0.5 arena-equivalents of bloat PER DELETE. So cckit cannot retract
/// arena documents at all. The workaround is append-only increments:
///
///  - A small delta (few changed/new/removed files) skips the arena reset.
///    Changed files' SQLite rows are replaced and their fresh documents append
///    to the arena; the stale twins of those documents leak in the arena until
///    the next full rebuild. Queries dedupe by qualified name and resolve
///    bodies from SQLite/disk, so the window is bounded-stale, not wrong.
///  - A full rebuild happens when the delta is large, the store is suspect
///    (no stamp, silent-empty, arena outside its expected allocation band),
///    or when leaked bytes have accumulated past the growth margin.
///
/// The stamp (`wax-compact-stamp.json`) is the allocation baseline written
/// after every completed rebuild; leaked appends grow the live file past it,
/// which is exactly the signal that bounds this scheme.
public enum WaxDeltaPolicy {

    /// Max files a single run may process incrementally. Each file re-embeds
    /// only itself (~1/1367 of a full run on the reference repo), so 32 keeps
    /// branch-switch updates in the seconds-to-a-minute range.
    public static let defaultMaxFiles = 32

    /// Fraction of the last-known-complete arena the leaked appends of delta
    /// runs may add before the next run must rebuild. Bounds the stale-twin
    /// window and the disk overhead of the append-only path.
    public static let defaultMaxGrowth = 0.10

    /// Absolute growth allowance on top of the margin. Wax's appends churn a
    /// near-fixed floor of index-segment bytes per delta (measured ~278KB on a
    /// 0.4MB arena), so a purely relative band would rebuild after every
    /// delta on small repos — whose rebuilds are NOT cheap (embedding time
    /// dominates). The allowance is what makes the incremental path usable
    /// across arena sizes; the margin still bounds leak on large ones.
    public static let defaultAllowanceBytes = 16_000_000

    /// An arena materially BELOW its baseline is truncated, not young — only a
    /// full rebuild restores missing documents. Mirrors WaxReadGate's floor.
    public static let shrinkFloor = 0.9

    /// Read via getenv, not ProcessInfo: ProcessInfo may snapshot the
    /// environment before tests (or embedding hosts) adjust it.
    private static func environmentValue(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    public static func maxFilesFromEnvironment() -> Int {
        guard let raw = environmentValue("CCKIT_WAX_DELTA_MAX_FILES"), let value = Int(raw) else {
            return defaultMaxFiles
        }
        return value
    }

    public static func maxGrowthFromEnvironment() -> Double {
        guard let raw = environmentValue("CCKIT_WAX_DELTA_MAX_GROWTH"), let value = Double(raw), value >= 0 else {
            return defaultMaxGrowth
        }
        return value
    }

    public static func allowanceBytesFromEnvironment() -> Int {
        guard let raw = environmentValue("CCKIT_WAX_DELTA_ALLOWANCE_BYTES"), let value = Int(raw), value >= 0 else {
            return defaultAllowanceBytes
        }
        return value
    }

    /// True when this run may append incrementally instead of replacing the arena.
    ///
    /// - `stampAllocatedBytes <= 0` means no completed rebuild has ever been
    ///   recorded (first index, or a stamp lost): rebuild so a baseline exists.
    /// - `arenaFrameCount == 0` with a populated keep-set is the silent-empty
    ///   poison (openable arena, zero retrievable documents): rebuild.
    public static func isEligible(
        forceRebuild: Bool,
        deltaFileCount: Int,
        stampAllocatedBytes: Int,
        arenaAllocatedBytes: Int,
        arenaFrameCount: Int,
        keepSetMandateCount: Int,
        maxFiles: Int = WaxDeltaPolicy.defaultMaxFiles,
        maxGrowth: Double = WaxDeltaPolicy.defaultMaxGrowth,
        allowanceBytes: Int = WaxDeltaPolicy.defaultAllowanceBytes
    ) -> Bool {
        if forceRebuild { return false }
        guard maxFiles > 0, deltaFileCount <= maxFiles else { return false }
        guard stampAllocatedBytes > 0 else { return false }
        if arenaFrameCount == 0, keepSetMandateCount > 0 { return false }
        // Truncated arenas never recover by appending.
        if Double(arenaAllocatedBytes) < Double(stampAllocatedBytes) * shrinkFloor { return false }
        // Leaked appends must stay within margin + absolute allowance.
        let growthCeiling = Double(stampAllocatedBytes) * (1.0 + maxGrowth) + Double(max(0, allowanceBytes))
        if Double(arenaAllocatedBytes) > growthCeiling { return false }
        return true
    }
}
