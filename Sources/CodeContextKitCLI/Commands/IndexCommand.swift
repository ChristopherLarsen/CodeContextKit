import ArgumentParser
import Foundation
import Darwin
import CodeContextKitCore
import CodeContextKitSwiftIndex
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Indexes a repository."
    )

    @Argument(help: "The directory to index.")
    var path: String = "."

    @Flag(help: "Clean the index before indexing.")
    var clean: Bool = false

    @Flag(help: "Rebuild the derived Wax semantic index from the current source tree.")
    var compact: Bool = false

    @Option(help: "Glob patterns to include.")
    var include: [String] = []

    @Option(help: "Glob patterns to exclude.")
    var exclude: [String] = []

    @Option(help: "Folder paths or names to exclude from indexing. Saved to .cckit/config.json when set.")
    var excludeFolder: [String] = []

    @Option(help: "Folder paths or names to index even when ignored by .gitignore. Saved to .cckit/config.json when set.")
    var includeFolder: [String] = []

    @Flag(help: "Print index statistics.")
    var stats: Bool = false

    @Flag(help: "Include Gradle .kts build scripts.")
    var includeBuildScripts: Bool = false

    @Flag(help: "Include generated Gradle/Kotlin source directories.")
    var includeGenerated: Bool = false

    /// Bytes actually materialized on disk (st_blocks). Wax preallocates
    /// arenas sparsely, so growth detection must use this, not st_size.
    /// Supersedes the apparent-size reader; one measurement for all callers.
    static func waxFileAllocatedBytes(at path: String) -> Int {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]) else { return 0 }
        let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        return max(0, allocated)
    }

    /// Marker written when a closed arena is still over the ceiling after a
    /// forced reclaim. The NEXT index run refuses on sight of it (the current
    /// run has already done its work by then); `--clean` or genuine recovery
    /// clears it.
    static let breachMarkerName = "wax-breach-marker.json"

    static func breachMarkerPath(_ cckitDir: String) -> String {
        (cckitDir as NSString).appendingPathComponent(breachMarkerName)
    }

    static func clearBreachMarker(cckitDir: String) {
        try? FileManager.default.removeItem(atPath: breachMarkerPath(cckitDir))
    }

    static func hasBreachMarker(cckitDir: String) -> Bool {
        FileManager.default.fileExists(atPath: breachMarkerPath(cckitDir))
    }

    static func writeBreachMarker(
        cckitDir: String,
        allocatedBytes: UInt64,
        expectedLiveBytes: UInt64,
        reclaimableBytes: UInt64,
        factor: Double
    ) {
        let payload: [String: Any] = [
            "allocatedBytes": allocatedBytes,
            "expectedLiveBytes": expectedLiveBytes,
            "reclaimableBytes": reclaimableBytes,
            "factor": factor,
            "detectedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: breachMarkerPath(cckitDir)), options: .atomic)
    }

    /// Sweep Wax live-set rewrite residue (ask G, extended to every run).
    ///
    /// Wax's scheduled rewrite writes `repo-liveset-<UUID>.wax` candidates
    /// beside the arena, prunes them only to `keepLatestCandidates: 2`, and
    /// promotes ONLY the close-time candidate — so every normal incremental
    /// run that triggers a mid-session rewrite leaves a full arena duplicate
    /// behind. The 2026-08-27 incident orphaned a 398 MB candidate that even
    /// survived a `--clean` rebuild. After close the handle is gone and any
    /// remaining candidate was by definition not promoted: unpromoted
    /// garbage. All arena writers hold the refresh lock while we sweep.
    ///
    /// `repo.wax.pre-liveset-*` backups are promotion byproducts. This helper is
    /// called only after a successful close or during a deliberate rebuild, so
    /// the authoritative arena is known and every remaining artifact is stale.
    static func sweepLiveSetResidue(cckitDir: String) {
        let result = WaxResidueSweeper.sweep(cckitDirectory: cckitDir)
        if result.removedFiles > 0 {
            print(
                "WaxResidue swept \(result.removedFiles) file(s), " +
                    "\(result.reclaimedAllocatedBytes)B allocated reclaimed."
            )
        }
        if !result.failures.isEmpty {
            print("Warning: Wax residue sweep could not remove: \(result.failures.joined(separator: "; "))")
        }
    }

    /// Single-line JSON summary for tooling; MCP keys off this instead of
    /// snapshotting repo.wax st_size after the run.
    static func machineReadableLine(for result: WaxCompactResult, stamped: Bool) -> String {
        var payload: [String: Any] = [
            "scanned": result.scanned,
            "deleted": result.deleted,
            "kept": result.kept,
            "bytesBefore": result.bytesBefore,
            "bytesAfter": result.bytesAfter,
            "shrank": result.shrank,
            "stamped": stamped,
            "rebuiltWax": result.rebuiltWax
        ]
        // Present only when the run actually indexed (compact-only passes
        // leave these out); a ledger row with durationMs but no counts cannot
        // distinguish a no-op from a near-full re-embed.
        if result.updated > 0 || result.skipped > 0 || result.totalSymbols > 0 {
            payload["updated"] = result.updated
            payload["skipped"] = result.skipped
            payload["symbols"] = result.totalSymbols
        }
        let name = "WaxCompact"
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return "\(name) \(json)"
        }
        return "\(name) {\"deleted\": \(result.deleted), \"shrank\": \(result.shrank), \"stamped\": \(stamped)}"
    }

    /// Marker prefix on stdout when this run dropped its work because another
    /// process already holds the refresh lock. The MCP shim parses it to report
    /// an honest skip instead of inferring success from exit 0.
    static let indexSkippedMarkerName = "IndexSkipped "

    static func indexSkippedLine(reason: String) -> String {
        let payload: [String: Any] = ["reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "\(indexSkippedMarkerName){\"reason\": \"locked\"}"
        }
        return "\(indexSkippedMarkerName)\(json)"
    }

    /// Ratio above which a withheld-stamp compaction must NOT relatch a
    /// baseline: certifying materialized bytes >= this multiple of
    /// expectedLiveBytes would hide known bloat behind a healthy watermark.
    /// Matches the compact-run warning print. Env-tunable for tests.
    static func settleBloatRatioThreshold() -> Double {
        guard let raw = ProcessInfo.processInfo.environment["CCKIT_WAX_SETTLE_RATIO"],
              let value = Double(raw.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return 2.0
        }
        return value
    }

    /// Called when a compact pass stamped nothing because nothing was
    /// reclaimed or shrunken. Four outcomes:
    ///  1. Watermark impossible vs live (>2× allocated, the pre-cc164a8 latch)
    ///     → restamp baseline immediately.
    ///  2. The post-close arena still breaches its expected live size → do NOT
    ///     relatch and do NOT count toward convergence: a run whose own
    ///     diagnostics say "repo.wax is Nx expected live" must not certify
    ///     those same bytes as healthy. Delegates to the breaker verdict so
    ///     the existing breach-marker contract arms (--clean owns remediation).
    ///  3. Second consecutive no-progress compact on a HEALTHY-ratio store →
    ///     relatch baseline so the shim's gate stops respawning forever.
    ///     Frame-level bloat shrinks and stamps via writeIfReclaimed;
    ///     stale-segment bloat ("scanned == kept") is excluded by (2) — it is
    ///     invisible to frame diffing, so deleted==0 proves nothing there.
    ///  4. First no-progress compact → bump the counter, keep the watermark,
    ///     allow one more attempt (cheap guard against a shrink racing us).
    /// Impossible-watermark ceiling mirrors
    /// mcp/cckit_mcp.py:_COMPACT_STAMP_MAX_LIVE_RATIO.
    @discardableResult
    static func settleWithheldCompactStamp(
        cckitDir: String,
        waxBytesAfter: Int,
        expectedLiveBytes: Int? = nil,
        reclaimableBytes: Int? = nil
    ) throws -> Bool {
        guard let prior = WaxCompactStamp.readWatermark(cckitDir: cckitDir) else {
            return false
        }
        let ceiling = max(1, waxBytesAfter) * 2
        if prior.waxBytes > ceiling {
            print(
                "Compact stamp impossible vs live store (\(prior.waxBytes) > \(ceiling), pre-cc164a8 latched watermark); restamping baseline."
            )
            try WaxCompactStamp.relatchBaseline(allocatedBytes: waxBytesAfter, cckitDir: cckitDir)
            return true
        }
        // Bloat veto: deleted==0 proves only that frame diffing found nothing —
        // segment-level dead weight never shows up there. Refuse certification
        // whenever the excess is RECOVERABLE (arm the marker, --clean owns it).
        // A breach whose excess has zero reclaimable bytes is fixed store
        // overhead by the breaker's own doctrine — same rationale as
        // settleWaxBreakerVerdict — so certification may proceed through the
        // normal convergence path below rather than looping loudly forever.
        let reclaimable = UInt64(exactly: max(0, reclaimableBytes ?? 0)) ?? 0
        if let expected = expectedLiveBytes, expected > 0,
           waxBytesAfter >= Int(Double(expected) * settleBloatRatioThreshold()) {
            if reclaimable > 0 {
                print(
                    "Withholding compact stamp: arena is past \(String(format: "%.1f", settleBloatRatioThreshold()))x its expected live size (\(waxBytesAfter)B vs ~\(expected)B, \(reclaimable)B reclaimable); refusing to latch bloat as healthy."
                )
                Self.writeBreachMarker(
                    cckitDir: cckitDir,
                    allocatedBytes: UInt64(max(0, waxBytesAfter)),
                    expectedLiveBytes: UInt64(expected),
                    reclaimableBytes: reclaimable,
                    factor: settleBloatRatioThreshold()
                )
                print(
                    "Breach marker armed: NEXT 'cckit index' aborts until 'cckit index . --clean' rebuilds from scratch."
                )
                return false
            }
            print(
                "Breach at \(String(format: "%.1f", settleBloatRatioThreshold()))x expected live size has no reclaimable bytes (store overhead); certifying is safe."
            )
        }
        if prior.noShrinkRuns >= 1 {
            print(
                "No-progress compact again (\(prior.noShrinkRuns + 1) consecutive); relatching baseline at \(waxBytesAfter) so needs-compact stops respawning."
            )
            try WaxCompactStamp.relatchBaseline(allocatedBytes: waxBytesAfter, cckitDir: cckitDir)
            return true
        }
        _ = try WaxCompactStamp.recordNoShrinkRun(cckitDir: cckitDir)
        return false
    }

    /// Mid-run arena cap (ask F): abort indexing while bytes are still being
    /// written, instead of the strictly post-hoc bloat veto. Cap is a factor
    /// over the pre-run arena, with an absolute floor so legitimately large
    /// repos are never clipped. Current Wax no longer exposes live-byte
    /// diagnostics publicly, so cckit relies on fresh filesystem allocation.
    /// Env-tunable: CCKIT_WAX_MIDRUN_FACTOR (default 8), CCKIT_WAX_MIN_BYTES
    /// (default 8 GiB), CCKIT_WAX_MIDRUN_CAP=off disables entirely.
    static func midRunArenaCap(
        mustRebuild: Bool,
        bytesBefore: Int
    ) -> Int? {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["CCKIT_WAX_MIDRUN_CAP"],
           mode.trimmingCharacters(in: .whitespaces).lowercased() == "off" {
            return nil
        }
        var factor = 8.0
        if let raw = env["CCKIT_WAX_MIDRUN_FACTOR"], let parsed = Double(raw), parsed > 0 {
            factor = parsed
        }
        var floorBytes = 8 * 1024 * 1024 * 1024
        if let raw = env["CCKIT_WAX_MIDRUN_MIN_BYTES"], let parsed = Int(raw), parsed > 0 {
            floorBytes = parsed
        }
        // On a rebuild the arena starts empty, so the old arena says nothing
        // about what this run should produce; the floor alone bounds it.
        let base = mustRebuild ? 0 : max(0, bytesBefore)
        return max(Int(Double(base) * factor), floorBytes)
    }

    func run() async throws {
        let startTime = Date()
        let cckitDir = ".cckit"
        let dbPath = "\(cckitDir)/index.sqlite"
        let waxPath = "\(cckitDir)/repo.wax"
        let fm = FileManager.default

        try fm.createDirectory(atPath: cckitDir, withIntermediateDirectories: true)

        // Single-writer gate before any store mutation (including --clean
        // rebuilds deleting db/wax). Held until run() returns; release happens
        // implicitly on process exit even on crash. RefreshLock verifies the
        // flocked inode still matches the path, so a delete-and-recreate of
        // refresh.lock mid-run (git clean, .cckit pruning) can no longer let
        // a second writer in — the failure shape behind the concurrent
        // full-index pileups.
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        guard let lock = RefreshLock.tryAcquire(lockPath: "\(cckitDir)/refresh.lock") else {
            print(Self.indexSkippedLine(reason: "locked"))
            // Record the drop so pileups are visible in the ledger instead of
            // silently disappearing (a skipped run previously left no trace).
            let orchestrator = ActionOrchestrator(repoRoot: ".")
            try? await orchestrator.recordCLIAction(
                command: fullCommand,
                toolName: "index",
                durationMs: 0,
                status: "skipped"
            )
            throw ExitCode.success
        }
        defer { lock.release() }

        // Hold a stable sidecar lease before inspecting or deleting repo.wax.
        // Wax locks the replaceable arena inode itself; that does not protect
        // against a long-lived server writing an unlinked old inode.
        let waxLease: RefreshLock.Lease
        do {
            waxLease = try WaxStore.acquireLease(for: waxPath)
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let storedEmbedderId = WaxEmbedderIdentity.storedId(cckitDir: cckitDir)
        let embedderMismatch = storedEmbedderId != WaxEmbedderIdentity.current
        let compactRequested = compact && !clean

        if compactRequested {
            guard fm.fileExists(atPath: dbPath), fm.fileExists(atPath: waxPath) else {
                print("Error: Index not found. Run 'cckit index .' first.")
                throw ExitCode.failure
            }
        }

        // Current Wax exposes neither in-place maintenance nor batch deletion.
        // A clean replacement is the only bounded cckit-owned compaction path.
        let hasExistingIndex = fm.fileExists(atPath: waxPath) || fm.fileExists(atPath: dbPath)
        let mustRebuild = clean
            || compactRequested
            || Self.hasBreachMarker(cckitDir: cckitDir)
            || (embedderMismatch && hasExistingIndex)

        if mustRebuild {
            if embedderMismatch && !clean {
                print("Semantic embedder changed (\(storedEmbedderId ?? "none") → \(WaxEmbedderIdentity.current)); rebuilding index for vector search...")
            }
            if compactRequested {
                print("Wax no longer exposes in-place compaction; rebuilding the derived index safely...")
            } else if Self.hasBreachMarker(cckitDir: cckitDir) {
                print("Wax breach marker found; rebuilding the derived index before opening it...")
            }
            if fm.fileExists(atPath: dbPath) {
                try fm.removeItem(atPath: dbPath)
            }
            if fm.fileExists(atPath: waxPath) {
                try fm.removeItem(atPath: waxPath)
            }
            // Ask G: --clean must remove Wax's live-set rewrite residue —
            // unpromoted candidates AND promotion backups; the arena they
            // reference is being deleted, and the 2026-08-27 rebuild left a
            // 398 MB repo-liveset-<UUID>.wax behind that had to be deleted
            // by hand.
            Self.sweepLiveSetResidue(cckitDir: cckitDir)
        }
        
        let db = try Database(path: dbPath)
        let bytesBeforeIndexing = Self.waxFileAllocatedBytes(at: waxPath)
        let wax = try await WaxStore(path: waxPath, lease: waxLease)
        guard await wax.isAvailable(), await wax.hasEmbeddings() else {
            // Ask B: name the real cause instead of pointing operators at
            // resource bundles that were fine during the 186 GB incident.
            var message = "Error: Failed to open MiniLM semantic store at \(waxPath)."
            if let openError = await wax.lastOpenError {
                message += " Cause: \(openError)"
            }
            print(message)
            throw ExitCode.failure
        }
        let actionOrchestrator = ActionOrchestrator(wax: wax)
        let indexer = Indexer(db: db, wax: wax)
        let absolutePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if !excludeFolder.isEmpty || !includeFolder.isEmpty {
            var settings = ProjectSettings.load(projectRoot: absolutePath)
            settings.excludedFolders = Array(Set(settings.excludedFolders + excludeFolder)).sorted()
            settings.includedFolders = Array(Set(settings.includedFolders + includeFolder)).sorted()
            try settings.save(projectRoot: absolutePath)
        }
        
        print("Indexing \(path)...")
        let stdoutIsTTY = isatty(STDOUT_FILENO) != 0

        if mustRebuild {
            Self.clearBreachMarker(cckitDir: cckitDir)
        }

        // Keep a fresh-filesystem mid-run cap. Wax no longer exposes public
        // live-byte diagnostics, and cckit no longer uses per-frame deletion.
        let arenaCap = Self.midRunArenaCap(
            mustRebuild: mustRebuild,
            bytesBefore: bytesBeforeIndexing
        )

        let compacted: WaxCompactResult
        do {
            compacted = try await indexer.index(
                at: path,
                include: include,
                exclude: exclude,
                includeBuildScripts: includeBuildScripts,
                includeGenerated: includeGenerated,
                maxArenaBytes: arenaCap,
                forceWaxRebuild: mustRebuild,
                delegate: CommandLineProgressDelegate(
                    emitProgress: InteractiveProgress.shouldEmitTTYProgress(stdoutIsTTY: stdoutIsTTY)
                )
            )
        } catch let error as IndexerError {
            // The cap tripped mid-run: arm the breach marker so the next run
            // refuses and points at --clean, using the same numbers the cap
            // just measured.
            if case .arenaGrowthCapExceeded(let allocated, _) = error {
                let expected = max(1, bytesBeforeIndexing)
                Self.writeBreachMarker(
                    cckitDir: cckitDir,
                    allocatedBytes: UInt64(max(0, allocated)),
                    expectedLiveBytes: UInt64(expected),
                    reclaimableBytes: UInt64(max(0, allocated - expected)),
                    factor: 8.0
                )
                print(
                    "Breach marker armed: NEXT 'cckit index' aborts until 'cckit index . --clean' rebuilds from scratch."
                )
            }
            throw error
        }

        try WaxEmbedderIdentity.writeSidecar(cckitDir: cckitDir)
        if let stamp = IndexFreshness.captureStamp(repoRoot: absolutePath) {
            try stamp.write(cckitDir: cckitDir)
        } else if let stamp = IndexFreshness.captureStamp(repoRoot: path) {
            // Fall back when absolutePath isn't a git root but `path` is cwd.
            try stamp.write(cckitDir: cckitDir)
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        // Ask H: persist the run's counts. The 21-minute 186 GB run recorded
        // only durationMs — there was no way to tell whether it re-embedded
        // the corpus or skipped it.
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "index",
            durationMs: duration,
            updated: compacted.updated,
            skipped: compacted.skipped,
            symbols: compacted.totalSymbols
        )

        // Close before final allocation accounting and residue cleanup.
        try await wax.close()
        // Collect unpromoted rewrite candidates and stale promotion backups
        // while we still hold the refresh lock (ask G: the rewrite leaves
        // full arena duplicates behind on normal incremental runs too).
        Self.sweepLiveSetResidue(cckitDir: cckitDir)
        let bytesAfterIndexing = Self.waxFileAllocatedBytes(at: waxPath)

        // Baseline stamps are only valid for stores built by construction
        // (explicit or change-triggered rebuild), where every byte is live.
        let stamped: Bool
        if mustRebuild || compacted.rebuiltWax {
            try WaxCompactStamp.writeBaseline(cckitDir: cckitDir)
            stamped = true
        } else {
            stamped = try WaxCompactStamp.writeIfReclaimed(
                cckitDir: cckitDir,
                deleted: compacted.deleted,
                bytesBefore: bytesBeforeIndexing,
                bytesAfter: bytesAfterIndexing
            )
            if !stamped, compacted.deleted > 0 {
                print(
                    "Compaction stamp withheld: file did not shrink " +
                    "(\(bytesBeforeIndexing) → \(bytesAfterIndexing) bytes); growth stays visible to MCP."
                )
            }
        }

        // Same telemetry on every index — growth on the plain path used to be
        // completely silent.
        print(Self.machineReadableLine(
            for: WaxCompactResult(
                scanned: compacted.scanned,
                deleted: compacted.deleted,
                kept: compacted.kept,
                bytesBefore: bytesBeforeIndexing,
                bytesAfter: bytesAfterIndexing,
                updated: compacted.updated,
                skipped: compacted.skipped,
                totalSymbols: compacted.totalSymbols,
                rebuiltWax: compacted.rebuiltWax
            ),
            stamped: stamped
        ))
    }
}

struct CommandLineProgressDelegate: IndexerProgressDelegate {
    let emitProgress: Bool

    func indexerDidStart(totalFiles: Int) {
        print("Starting indexing of \(totalFiles) files...")
    }

    func indexerDidProgress(completedFiles: Int, totalFiles: Int, currentFile: String) {
        guard emitProgress else { return }
        let percent = totalFiles > 0 ? (completedFiles * 100 / totalFiles) : 0
        InteractiveProgress.write("[\(percent)%] \(currentFile)\n", to: .standardError)
    }

    func indexerDidFinish(updated: Int, skipped: Int, totalSymbols: Int) {
        print("Indexing complete. Updated: \(updated), Skipped: \(skipped), Symbols: \(totalSymbols)")
    }

    func indexerDidFail(error: Error) {
        print("Indexing failed: \(error.localizedDescription)")
    }
}
