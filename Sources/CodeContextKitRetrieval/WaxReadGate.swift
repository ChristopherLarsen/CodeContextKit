import Foundation
import CodeContextKitStorage

/// Hard fault or ride-along warning for a read against a degraded arena.
///
/// The 2026-08-28 incident class: the arena OPENS fine but is not serviceable.
/// `requireEmbeddings()` passes, no error is raised, and `pack` returns a
/// well-formed packet with `primary: 0 symbols` — indistinguishable from
/// "this repo genuinely has nothing relevant". Silence is indistinguishable
/// from an answer, and an agent that receives `0 symbols` concludes its
/// target does not exist. This gate runs on every read (pack, search, serve)
/// BEFORE results are trusted.
public enum WaxReadGate {

    public enum Fault: Error, LocalizedError, Equatable, Sendable {
        /// The arena is materially smaller than the last known-complete arena
        /// for this repo. An interrupted rebuild (SIGTERM mid-write) leaves a
        /// partial arena that still opens and serves — a confident false
        /// negative generator, not an empty index.
        case truncatedArena(expectedAllocatedBytes: Int, actualAllocatedBytes: Int)
        /// Files in the SQLite keep-set have no Wax coverage row for the
        /// current arena generation: a rebuild is unfinished (in flight or
        /// was killed). SQLite coverage markers make this retryable; the gap
        /// was that reads served the partial arena instead of saying so.
        case rebuildIncomplete(uncoveredFiles: Int, samplePaths: [String])
        /// The arena opens and holds zero frames while the SQLite keep-set
        /// records ingested documents — the silent-empty poison. Retrieval
        /// would return a confident `0 results` against content that exists.
        case emptyArena(populatedMandates: Int)

        public var errorDescription: String? {
            switch self {
            case .truncatedArena(let expected, let actual):
                return "Wax arena is truncated: \(actual)B materialized vs \(expected)B for the last " +
                    "known-complete arena. Semantic results would be silently partial. " +
                    "Run 'cckit index .' to finish the rebuild."
            case .rebuildIncomplete(let count, let sample):
                var message = "Wax rebuild incomplete: \(count) indexed file(s) have no coverage in the current " +
                    "arena (a rebuild is in flight or did not finish)."
                if !sample.isEmpty {
                    message += " First missing: \(sample.joined(separator: ", "))."
                }
                message += " Run 'cckit index .' to finish the rebuild."
                return message
            case .emptyArena(let mandates):
                return "Wax arena holds 0 frames but the index keep-set records \(mandates) ingested " +
                    "documents; semantic results would be silently empty. " +
                    "Run 'cckit index .' to rebuild."
            }
        }
    }

    public struct Report: Sendable {
        /// Results must not be served when set.
        public let hardFault: Fault?
        /// Armed breach marker: results may still be delivered, but every
        /// response carries the marker's numbers and the --clean contract.
        public let breachWarning: String?

        public var isDegraded: Bool { hardFault != nil || breachWarning != nil }

        public init(hardFault: Fault?, breachWarning: String?) {
            self.hardFault = hardFault
            self.breachWarning = breachWarning
        }
    }

    /// Ratio thresholds for truncation. Below 3x a smaller arena is ordinary
    /// churn; above 64x the stamp is an impossible pre-cc164a8 latched
    /// watermark (observed 1388x), not truncation — mirrors the shim's
    /// _COMPACT_STAMP_MAX_LIVE_RATIO doctrine in reverse.
    public static let truncationMinRatio: Double = 3.0
    public static let truncationMaxRatio: Double = 64.0
    /// Stamps under this floor describe tiny/young stores where ratio noise
    /// is meaningless; mirrors WaxBloatGuard's small-store guard.
    public static let expectedFloorBytes: Int = 4_000_000

    /// Pure decision core. `expectedAllocatedBytes` is the compact stamp —
    /// cckit writes it after every completed rebuild, so it records the
    /// allocated size of the last known-complete arena for this content.
    /// `arenaFrameCount` / `keepSetMandateCount` default to a neutral "no
    /// evidence" pair for callers that cannot cheaply produce both.
    public static func hardFault(
        allocatedBytes: Int,
        expectedAllocatedBytes: Int,
        uncoveredExistingPaths: [String],
        arenaFrameCount: Int = 0,
        keepSetMandateCount: Int = 0
    ) -> Fault? {
        if expectedAllocatedBytes >= expectedFloorBytes, allocatedBytes >= 0 {
            let ratio = Double(expectedAllocatedBytes) / Double(max(1, allocatedBytes))
            if ratio >= truncationMinRatio, ratio <= truncationMaxRatio {
                return .truncatedArena(
                    expectedAllocatedBytes: expectedAllocatedBytes,
                    actualAllocatedBytes: allocatedBytes
                )
            }
        }
        if arenaFrameCount == 0, keepSetMandateCount > 0 {
            return .emptyArena(populatedMandates: keepSetMandateCount)
        }
        if !uncoveredExistingPaths.isEmpty {
            return .rebuildIncomplete(
                uncoveredFiles: uncoveredExistingPaths.count,
                samplePaths: Array(uncoveredExistingPaths.prefix(5))
            )
        }
        return nil
    }

    /// Full evaluation for a read command. Cheap: one marker read, one stamp
    /// read, one arena stat, one indexed SQLite query.
    public static func evaluate(
        waxPath: String,
        cckitDir: String,
        db: Database,
        wax: WaxStore
    ) async -> Report {
        let marker = WaxStore.readBreachMarker(near: waxPath)
        let warning = marker.map { WaxStore.breachWarningText(for: $0) }

        // Uncovered paths must exist on disk to indicate an unfinished
        // rebuild; an interrupted run's cleanup phase never removed rows for
        // files deleted from disk, and those are not evidence.
        var uncoveredExisting: [String] = []
        if let uncovered = try? db.uncoveredWaxFilePaths() {
            uncoveredExisting = uncovered.filter { FileManager.default.fileExists(atPath: $0) }
        }

        let expected = WaxCompactStamp.readWatermark(cckitDir: cckitDir)?.waxBytes ?? 0
        let allocated = await wax.allocatedBytes()
        let fault = hardFault(
            allocatedBytes: allocated,
            expectedAllocatedBytes: expected,
            uncoveredExistingPaths: uncoveredExisting,
            arenaFrameCount: await wax.frameCount(),
            keepSetMandateCount: (try? db.waxMandateCount()) ?? 0
        )
        return Report(hardFault: fault, breachWarning: warning)
    }
}
