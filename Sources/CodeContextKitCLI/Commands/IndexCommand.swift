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

    @Flag(
        name: .long,
        help: """
            Index SQLite locators only — skip the Wax semantic arena entirely \
            (no embeddings, no ~18-minute rebuild, no repo.wax). Locators, map, \
            outline, and pack (locators-only) are unaffected; vector search is \
            unavailable while this is the exclusive mode. Also honors \
            CCKIT_NO_SEMANTIC=1. The mode persists via .cckit/lexical-only \
            across later `cckit index` runs; set CCKIT_NO_SEMANTIC=0 to build \
            the semantic arena again.
            """
    )
    var noSemantic: Bool = false

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

    /// Marker written when an index run aborts with the arena over its
    /// mid-run cap, or when a compact lands past the settle bloat ratio with
    /// reclaimable bytes. The NEXT index run routes into a full staged
    /// rebuild on sight of it and clears the marker only after a successful
    /// swap; reads carry the warning until then. `--clean` or genuine recovery
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
        if result.deltaApplied {
            payload["delta"] = true
        }
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
                    "Breach marker armed: the next 'cckit index' rebuilds the arena from scratch (staged swap); reads carry the breach warning until it completes."
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
    /// Env-tunable: CCKIT_WAX_MIDRUN_FACTOR (default 8),
    /// CCKIT_WAX_MIDRUN_MIN_BYTES (default 8 GiB), CCKIT_WAX_MIDRUN_CAP=off
    /// disables entirely.
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

        // Every terminal state leaves exactly one ledger row. Failed index
        // runs used to vanish (the embeddings guard threw before the recorder
        // existed), silently biasing every effectiveness measurement taken
        // from action_history.jsonl — including "11 failures, 1 success".
        let ledger = ActionOrchestrator(repoRoot: ".")
        do {
            try await runIndex(
                cckitDir: cckitDir,
                fullCommand: fullCommand,
                startTime: startTime,
                ledger: ledger
            )
        } catch {
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            let reason = String(describing: error)
            try? await ledger.recordCLIAction(
                command: fullCommand,
                toolName: "index",
                durationMs: duration,
                status: "failed",
                response: String(reason.prefix(2000))
            )
            throw error
        }
    }


    /// A failure that carries its operator-facing reason into the ledger row
    /// (ExitCode alone records only `ExitCode(rawValue: 1)`).
    struct IndexFailure: LocalizedError {
        let reason: String
        public var errorDescription: String? { reason }
    }

    /// Snapshot-swap support lives in `IndexSwap` (CodeContextKitContext) so
    /// it is testable and shared.
    private func runIndex(
        cckitDir: String,
        fullCommand: String,
        startTime: Date,
        ledger: ActionOrchestrator
    ) async throws {
        let dbPath = "\(cckitDir)/index.sqlite"
        let waxPath = "\(cckitDir)/repo.wax"
        let fm = FileManager.default
        let lexicalOnly = SemanticIndexPolicy.lexicalOnlyRequested(flag: noSemantic, cckitDir: cckitDir)

        // Hold a stable sidecar lease before inspecting or deleting repo.wax.
        // Wax locks the replaceable arena inode itself; that does not protect
        // against a long-lived server writing an unlinked old inode. Lexical
        // runs never touch the arena, so they need no arena lease.
        let waxLease: RefreshLock.Lease?
        if lexicalOnly {
            waxLease = nil
        } else {
            do {
                waxLease = try WaxStore.acquireLease(for: waxPath)
            } catch {
                print("Error: \(error.localizedDescription)")
                throw IndexFailure(reason: "arena lease unavailable: \(error.localizedDescription)")
            }
        }
        defer { waxLease?.release() }

        let storedEmbedderId = lexicalOnly ? nil : WaxEmbedderIdentity.storedId(cckitDir: cckitDir)
        let embedderMismatch = !lexicalOnly && storedEmbedderId != WaxEmbedderIdentity.current
        let compactRequested = compact && !clean

        if compactRequested {
            guard fm.fileExists(atPath: dbPath), fm.fileExists(atPath: waxPath) else {
                print("Error: Index not found. Run 'cckit index .' first.")
                throw ExitCode.failure
            }
        }
        if lexicalOnly && compact {
            print("Error: --compact rebuilds the semantic arena; incompatible with --no-semantic.")
            throw IndexFailure(reason: "--compact is incompatible with --no-semantic")
        }

        // Current Wax exposes neither in-place maintenance nor batch deletion.
        // A clean replacement is the only bounded cckit-owned compaction path.
        let hasExistingIndex = fm.fileExists(atPath: waxPath) || fm.fileExists(atPath: dbPath)
        // Breach markers and embedder mismatches are semantic concerns; a
        // lexical-only run must not nuke SQLite over them.
        let mustRebuild = lexicalOnly
            ? clean
            : clean
                || compactRequested
                || Self.hasBreachMarker(cckitDir: cckitDir)
                || (embedderMismatch && hasExistingIndex)

        if mustRebuild && !lexicalOnly {
            if embedderMismatch && !clean {
                print("Semantic embedder changed (\(storedEmbedderId ?? "none") → \(WaxEmbedderIdentity.current)); rebuilding index for vector search...")
            }
            if compactRequested {
                print("Wax no longer exposes in-place compaction; rebuilding the derived index safely...")
            } else if Self.hasBreachMarker(cckitDir: cckitDir) {
                print("Wax breach marker found; rebuilding the derived index before opening it...")
            }
        }

        // Snapshot rebuild: build db (+ arena) in a staging directory while
        // the live index keeps serving complete, consistent reads. Band- and
        // breach-driven rebuilds used to mutate index.sqlite in place for the
        // full ~18-minute build; --clean deleted both stores up front, taking
        // every tool down. Now nothing live is touched until the atomic swap.
        let stagingDir = "\(cckitDir)/staging"
        if mustRebuild {
            try? fm.removeItem(atPath: stagingDir)
            try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        }
        let buildDbPath = mustRebuild ? "\(stagingDir)/index.sqlite" : dbPath
        let buildWaxPath = mustRebuild ? "\(stagingDir)/repo.wax" : waxPath

        let db = try Database(path: buildDbPath)
        let bytesBeforeIndexing = Self.waxFileAllocatedBytes(at: waxPath)

        var stagingWaxLease: RefreshLock.Lease?
        var wax: WaxStore?
        // Backstop for the throw paths below; the success path releases this
        // explicitly before the swap. release() is idempotent.
        defer { stagingWaxLease?.release() }
        if !lexicalOnly {
            do {
                if mustRebuild {
                    // Staged build: the staging arena needs its own lease; the
                    // live lease stays held so concurrent writers stay out.
                    stagingWaxLease = try WaxStore.acquireLease(for: buildWaxPath)
                    wax = try await WaxStore(path: buildWaxPath, lease: stagingWaxLease!)
                } else {
                    // Same path as the live arena — reuse the live lease; a
                    // second flock on the same file deadlocks even in-process.
                    wax = try await WaxStore(path: buildWaxPath, lease: waxLease!)
                }
            } catch {
                print("Error: \(error.localizedDescription)")
                throw IndexFailure(reason: "semantic store failed to open: \(error.localizedDescription)")
            }
        }
        if let wax {
            guard await wax.isAvailable(), await wax.hasEmbeddings() else {
                // Ask B: name the real cause instead of pointing operators at
                // resource bundles that were fine during the 186 GB incident.
                var message = "Error: Failed to open MiniLM semantic store at \(buildWaxPath)."
                if let openError = await wax.lastOpenError {
                    message += " Cause: \(openError)"
                }
                print(message)
                throw IndexFailure(reason: message)
            }
        }
        let indexer = Indexer(db: db, wax: wax)
        let absolutePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if !excludeFolder.isEmpty || !includeFolder.isEmpty {
            var settings = ProjectSettings.load(projectRoot: absolutePath)
            settings.excludedFolders = Array(Set(settings.excludedFolders + excludeFolder)).sorted()
            settings.includedFolders = Array(Set(settings.includedFolders + includeFolder)).sorted()
            try settings.save(projectRoot: absolutePath)
        }

        print("Indexing \(path)\(lexicalOnly ? " (lexical-only)" : "")...")
        let stdoutIsTTY = isatty(STDOUT_FILENO) != 0

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
            if case .arenaGrowthCapExceeded(let allocated, _) = error, !lexicalOnly {
                let expected = max(1, bytesBeforeIndexing)
                Self.writeBreachMarker(
                    cckitDir: cckitDir,
                    allocatedBytes: UInt64(max(0, allocated)),
                    expectedLiveBytes: UInt64(expected),
                    reclaimableBytes: UInt64(max(0, allocated - expected)),
                    factor: 8.0
                )
                print(
                    "Breach marker armed: the next 'cckit index' rebuilds the arena from scratch (staged swap); reads carry the breach warning until it completes."
                )
            }
            throw error
        }

        // Close staging stores before the swap so no handle outlives the
        // inode it built.
        if let wax {
            try await wax.close()
        }
        stagingWaxLease?.release()
        stagingWaxLease = nil
        try db.close()

        if mustRebuild {
            try IndexSwap.swapBuildIntoPlace(
                cckitDir: cckitDir,
                stagingDir: stagingDir,
                dbPath: dbPath,
                waxPath: waxPath,
                includeWax: !lexicalOnly
            )
            // The live store was breaching until this moment; only a
            // completed swap retires the marker.
            if !lexicalOnly {
                Self.clearBreachMarker(cckitDir: cckitDir)
            }
            if clean && lexicalOnly {
                // Lexical --clean drops the arena outright; it is never
                // rebuilt until a semantic run is requested.
                try? fm.removeItem(atPath: waxPath)
            }
        }

        // The lexical-only marker persists the mode across processes (see
        // SemanticIndexPolicy.lexicalOnlyRequested): the MCP shim's auto-refresh
        // spawns `index --no-semantic` from it instead of silently upgrading the
        // repo to a full semantic build, and every read (pack, search) honors it.
        // Written only after the successful build (post-swap): last successful
        // run wins.
        let lexicalMarkerPath = SemanticIndexPolicy.lexicalOnlyMarkerPath(cckitDir: cckitDir)
        if lexicalOnly {
            try? Data("1\n".utf8).write(to: URL(fileURLWithPath: lexicalMarkerPath), options: .atomic)
        } else {
            try? fm.removeItem(atPath: lexicalMarkerPath)
        }

        // Collect unpromoted rewrite candidates and stale promotion backups
        // while we still hold the refresh lock (ask G: the rewrite leaves
        // full arena duplicates behind on normal incremental runs too).
        Self.sweepLiveSetResidue(cckitDir: cckitDir)
        let bytesAfterIndexing = Self.waxFileAllocatedBytes(at: waxPath)

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        // Ask H: persist the run's counts. The 21-minute 186 GB run recorded
        // only durationMs — there was no way to tell whether it re-embedded
        // the corpus or skipped it.
        try? await ledger.recordCLIAction(
            command: fullCommand,
            toolName: "index",
            durationMs: duration,
            updated: compacted.updated,
            skipped: compacted.skipped,
            symbols: compacted.totalSymbols
        )

        // Freshness stamp applies to every completed run (lexical included):
        // it is the shim's "index is current vs HEAD" signal, and a rebuild
        // that forgets it would be re-refreshed on every MCP call.
        if let stamp = IndexFreshness.captureStamp(repoRoot: absolutePath)
            ?? IndexFreshness.captureStamp(repoRoot: path) {
            try stamp.write(cckitDir: cckitDir)
        }

        // Baseline stamps are only valid for stores built by construction
        // (explicit or change-triggered rebuild), where every byte is live.
        let stamped: Bool
        if lexicalOnly {
            // A lexical run claims nothing about the arena's allocation
            // baseline; leave semantic stamps and sidecars untouched.
            stamped = false
        } else if mustRebuild || compacted.rebuiltWax {
            try WaxEmbedderIdentity.writeSidecar(cckitDir: cckitDir)
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
        if !lexicalOnly && !mustRebuild {
            try WaxEmbedderIdentity.writeSidecar(cckitDir: cckitDir)
        }

        // Same telemetry on every index — growth on the plain path used to be
        // completely silent. appendedBytes makes the per-commit append cost a
        // measurement instead of an inference (a delta commit appends the
        // entire staged FTS+vector blobs upstream — ~0.5 arena-equivalents).
        var payload: [String: Any] = [
            "scanned": compacted.scanned,
            "deleted": compacted.deleted,
            "kept": compacted.kept,
            "bytesBefore": bytesBeforeIndexing,
            "bytesAfter": bytesAfterIndexing,
            "shrank": bytesAfterIndexing < bytesBeforeIndexing,
            "stamped": stamped,
            "rebuiltWax": compacted.rebuiltWax
        ]
        if compacted.deltaApplied {
            payload["delta"] = true
            payload["appendedBytes"] = max(0, bytesAfterIndexing - bytesBeforeIndexing)
        }
        if lexicalOnly {
            payload["lexicalOnly"] = true
        }
        // Present only when the run actually indexed (compact-only passes
        // leave these out); a ledger row with durationMs but no counts cannot
        // distinguish a no-op from a near-full re-embed.
        if compacted.updated > 0 || compacted.skipped > 0 || compacted.totalSymbols > 0 {
            payload["updated"] = compacted.updated
            payload["skipped"] = compacted.skipped
            payload["symbols"] = compacted.totalSymbols
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("WaxCompact \(json)")
        } else {
            print(Self.machineReadableLine(for: WaxCompactResult(
                scanned: compacted.scanned,
                deleted: compacted.deleted,
                kept: compacted.kept,
                bytesBefore: bytesBeforeIndexing,
                bytesAfter: bytesAfterIndexing,
                updated: compacted.updated,
                skipped: compacted.skipped,
                totalSymbols: compacted.totalSymbols,
                rebuiltWax: compacted.rebuiltWax,
                deltaApplied: compacted.deltaApplied
            ), stamped: stamped))
        }
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
