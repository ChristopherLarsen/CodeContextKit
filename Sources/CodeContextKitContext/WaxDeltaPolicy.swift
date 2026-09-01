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
///
/// Measured append economics (2026-08 instrumentation window): Wax's commit
/// writes the ENTIRE staged FTS blob + vector blob + a complete TOC, so a
/// one-symbol delta costs the same ~0.5 arena-equivalents as a thousand-symbol
/// one (~61 MB observed on a 128 MB arena). Growth is per-commit, not
/// per-content. The allowance therefore scales with the baseline
/// (`defaultAllowanceScale`) so the band survives several commits of any size;
/// the nightly/off-hours snapshot rebuild (build-to-the-side-and-swap) is what
/// actually bounds twin accumulation over time.
public enum WaxDeltaPolicy {

    /// Max files a single run may process incrementally. Each file re-embeds
    /// only itself (~1/1367 of a full run on the reference repo), so 32 keeps
    /// branch-switch updates in the seconds-to-a-minute range.
    public static let defaultMaxFiles = 32

    /// Fraction of the last-known-complete arena the leaked appends of delta
    /// runs may add before the next run must rebuild. Bounds the stale-twin
    /// window and the disk overhead of the append-only path.
    public static let defaultMaxGrowth = 0.10

    /// Absolute growth allowance floor on top of the margin. Wax's appends churn a
    /// near-fixed floor of index-segment bytes per delta (measured ~278KB on a
    /// 0.4MB arena), so a purely relative band would rebuild after every
    /// delta on small repos — whose rebuilds are NOT cheap (embedding time
    /// dominates). The allowance is what makes the incremental path usable
    /// across arena sizes; the margin still bounds leak on large ones.
    public static let defaultAllowanceBytes = 16_000_000

    /// Baseline-scaled allowance: effective allowance is
    /// `max(allowanceBytes, stampAllocatedBytes * allowanceScale)`. Wax's
    /// per-commit append is ~0.5 arena-equivalents REGARDLESS of payload, so
    /// the allowance must ride the baseline: 1.5 covers ~3 commits per day
    /// before a rebuild, with the snapshot rebuild bounding twins over time.
    /// Env-tunable: CCKIT_WAX_DELTA_ALLOWANCE_SCALE.
    public static let defaultAllowanceScale = 1.5

    /// An arena materially BELOW its baseline is truncated, not young — only a
    /// full rebuild restores missing documents. Mirrors WaxReadGate's floor.
    public static let shrinkFloor = 0.9

    /// The eligibility verdict with its arithmetic attached, so an operator
    /// never has to infer why a rebuild happened.
    public struct Decision: Sendable, Equatable {
        public let eligible: Bool
        /// Which predicate refused (nil when eligible): forceRebuild,
        /// maxFiles, noStamp, silentEmpty, truncatedArena, growthCeiling.
        public let refusedBy: String?
        public let deltaFileCount: Int
        public let maxFiles: Int
        public let stampAllocatedBytes: Int
        public let arenaAllocatedBytes: Int
        public let growthCeilingBytes: Int
        public let effectiveAllowanceBytes: Int
        public let allowanceScale: Double

        public var summary: String {
            var payload: [String: Any] = [
                "eligible": eligible,
                "deltaFiles": deltaFileCount,
                "maxFiles": maxFiles,
                "stampBytes": stampAllocatedBytes,
                "arenaBytes": arenaAllocatedBytes,
                "growthCeiling": growthCeilingBytes,
                "allowance": effectiveAllowanceBytes,
            ]
            if let refusedBy {
                payload["refusedBy"] = refusedBy
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return eligible ? "DeltaDecision {\"eligible\": true}" : "DeltaDecision {\"eligible\": false}"
            }
            return "DeltaDecision \(json)"
        }
    }

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

    public static func allowanceScaleFromEnvironment() -> Double {
        guard let raw = environmentValue("CCKIT_WAX_DELTA_ALLOWANCE_SCALE"),
              let value = Double(raw), value >= 0 else {
            return defaultAllowanceScale
        }
        return value
    }

    /// Effective allowance: the absolute floor OR the baseline-scaled value,
    /// whichever is larger. Scales with the arena because Wax's per-commit
    /// append is a near-fixed fraction OF the arena, not of the delta.
    public static func effectiveAllowance(
        stampAllocatedBytes: Int,
        allowanceBytes: Int,
        allowanceScale: Double
    ) -> Int {
        let scaled = Int((Double(max(0, stampAllocatedBytes)) * max(0, allowanceScale)).rounded())
        return max(max(0, allowanceBytes), scaled)
    }

    /// Full eligibility verdict — see `Decision`. Prefer calling this and
    /// logging `decision.summary`; the boolean `isEligible` wrapper stays for
    /// existing call sites.
    public static func evaluate(
        forceRebuild: Bool,
        deltaFileCount: Int,
        stampAllocatedBytes: Int,
        arenaAllocatedBytes: Int,
        arenaFrameCount: Int,
        keepSetMandateCount: Int,
        maxFiles: Int = WaxDeltaPolicy.defaultMaxFiles,
        maxGrowth: Double = WaxDeltaPolicy.defaultMaxGrowth,
        allowanceBytes: Int = WaxDeltaPolicy.defaultAllowanceBytes,
        allowanceScale: Double = WaxDeltaPolicy.defaultAllowanceScale
    ) -> Decision {
        func refused(_ by: String) -> Decision {
            Decision(
                eligible: false,
                refusedBy: by,
                deltaFileCount: deltaFileCount,
                maxFiles: maxFiles,
                stampAllocatedBytes: stampAllocatedBytes,
                arenaAllocatedBytes: arenaAllocatedBytes,
                growthCeilingBytes: 0,
                effectiveAllowanceBytes: 0,
                allowanceScale: allowanceScale
            )
        }

        if forceRebuild { return refused("forceRebuild") }
        guard maxFiles > 0, deltaFileCount <= maxFiles else { return refused("maxFiles") }
        guard stampAllocatedBytes > 0 else { return refused("noStamp") }
        if arenaFrameCount == 0, keepSetMandateCount > 0 { return refused("silentEmpty") }
        // Truncated arenas never recover by appending.
        if Double(arenaAllocatedBytes) < Double(stampAllocatedBytes) * shrinkFloor {
            return refused("truncatedArena")
        }
        // Leaked appends must stay within margin + baseline-scaled allowance.
        let allowance = effectiveAllowance(
            stampAllocatedBytes: stampAllocatedBytes,
            allowanceBytes: allowanceBytes,
            allowanceScale: allowanceScale
        )
        let growthCeiling = Double(stampAllocatedBytes) * (1.0 + maxGrowth) + Double(allowance)
        if Double(arenaAllocatedBytes) > growthCeiling { return refused("growthCeiling") }
        return Decision(
            eligible: true,
            refusedBy: nil,
            deltaFileCount: deltaFileCount,
            maxFiles: maxFiles,
            stampAllocatedBytes: stampAllocatedBytes,
            arenaAllocatedBytes: arenaAllocatedBytes,
            growthCeilingBytes: Int(growthCeiling),
            effectiveAllowanceBytes: allowance,
            allowanceScale: allowanceScale
        )
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
        evaluate(
            forceRebuild: forceRebuild,
            deltaFileCount: deltaFileCount,
            stampAllocatedBytes: stampAllocatedBytes,
            arenaAllocatedBytes: arenaAllocatedBytes,
            arenaFrameCount: arenaFrameCount,
            keepSetMandateCount: keepSetMandateCount,
            maxFiles: maxFiles,
            maxGrowth: maxGrowth,
            allowanceBytes: allowanceBytes
        ).eligible
    }
}
