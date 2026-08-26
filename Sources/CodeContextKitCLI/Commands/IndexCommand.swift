import ArgumentParser
import Foundation
import Darwin
import CodeContextKitCore
import CodeContextKitSwiftIndex
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext
import Wax

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Indexes a repository."
    )

    @Argument(help: "The directory to index.")
    var path: String = "."

    @Flag(help: "Clean the index before indexing.")
    var clean: Bool = false

    @Flag(help: "Drop Wax vectors not in the current SQLite symbol set, without re-embedding.")
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

    /// Item 7 circuit breaker, phase 1 (pre-index): when the arena far exceeds
    /// its expected live size, force the live-set rewrite — but never judge it
    /// here. The rewrite only replaces the file at close, so any post-reclaim
    /// read in this phase sees stale bytes (the bug that made every index fail
    /// on the run that fixed the arena). Verdict happens post-close in
    /// ``settleWaxBreakerVerdict(cckitDir:wax:)``. Comparison uses allocated
    /// (materialized) bytes — Wax preallocates arenas sparsely, so logical
    /// size false-positives on young stores.
    private func enforceWaxBloatBreaker(_ wax: WaxStore, cckitDir: String) async throws {
        let factor = WaxBloatGuard.factorFromEnvironment()
        guard let diag = try? await wax.storeDiagnostics(),
              WaxBloatGuard.isBreached(
                  fileBytes: diag.allocatedBytes,
                  expectedLiveBytes: diag.expectedLiveBytes,
                  factor: factor
              )
        else {
            // Healthy again (manual cleanup, prior close reclaimed): self-heal.
            Self.clearBreachMarker(cckitDir: cckitDir)
            return
        }

        if Self.hasBreachMarker(cckitDir: cckitDir) {
            // A previous run already forced a reclaim and still closed over
            // the ceiling. Refuse before doing more work.
            print(
                "Error: repo.wax remains over \(Int(factor))x its live set after a prior forced reclaim " +
                    "(currently \(diag.allocatedBytes)B materialized vs ~\(diag.expectedLiveBytes)B live, " +
                    "\(diag.reclaimableBytes)B reclaimable). Run 'cckit index . --clean' to rebuild from scratch."
            )
            throw ExitCode.failure
        }

        print(
            "WaxBreaker repo.wax=\(diag.allocatedBytes)B materialized vs expected live ~\(diag.expectedLiveBytes)B " +
                "(staleSegments=\(diag.staleSegmentBytes)B, deadPayload=\(diag.deadFramePayloadBytes)B); forcing live-set reclaim."
        )
        if let summary = try? await wax.runLiveSetReclaimNow() {
            print(
                "WaxMaintenance outcome=\(summary.outcome.rawValue) reclaimed=\(summary.reclaimedBytes)B " +
                    "deadFraction=\(String(format: "%.2f", summary.deadPayloadFraction))"
            )
        }
        // Deliberately no verdict here: reclaimed bytes only appear at close.
    }

    /// Item 7 circuit breaker, phase 2 (post-close): the store is closed, so
    /// the on-disk file now reflects any promoted rewrite. Judges this run's
    /// reclaim against the pre-close diagnostics snapshot and real materialized
    /// size; arms (or clears) the fail-fast marker for the NEXT invocation.
    /// This run's work is persisted either way — never fails this run.
    static func settleWaxBreakerVerdict(
        cckitDir: String,
        snapshot: StoreDiagnostics,
        materializedAfterClose: Int
    ) {
        let factor = WaxBloatGuard.factorFromEnvironment()
        guard WaxBloatGuard.isBreached(
            fileBytes: UInt64(max(0, materializedAfterClose)),
            expectedLiveBytes: snapshot.expectedLiveBytes,
            factor: factor
        ) else {
            Self.clearBreachMarker(cckitDir: cckitDir)
            return
        }

        if snapshot.reclaimableBytes == 0 {
            // Nothing left to drop: the remaining gap is fixed store overhead
            // (header/WAL/TOC pages), not garbage.
            print("WaxBreaker: no reclaimable bytes remain; residual size is store overhead.")
            Self.clearBreachMarker(cckitDir: cckitDir)
            return
        }

        Self.writeBreachMarker(
            cckitDir: cckitDir,
            allocatedBytes: UInt64(max(0, materializedAfterClose)),
            expectedLiveBytes: snapshot.expectedLiveBytes,
            reclaimableBytes: snapshot.reclaimableBytes,
            factor: factor
        )
        print(
            "Warning: repo.wax still exceeds \(Int(factor))x its live set at close " +
                "(\(materializedAfterClose)B materialized vs ~\(snapshot.expectedLiveBytes)B, \(snapshot.reclaimableBytes)B reclaimable). " +
                "This index persisted; the NEXT 'cckit index' will abort until 'cckit index . --clean' rebuilds."
        )
    }

    /// Single-line JSON summary for tooling; MCP keys off this instead of
    /// snapshotting repo.wax st_size after the run.
    static func machineReadableLine(for result: WaxCompactResult, stamped: Bool) -> String {
        let payload: [String: Any] = [
            "scanned": result.scanned,
            "deleted": result.deleted,
            "kept": result.kept,
            "bytesBefore": result.bytesBefore,
            "bytesAfter": result.bytesAfter,
            "shrank": result.shrank,
            "stamped": stamped
        ]
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

    /// Called when a compact pass stamped nothing because nothing was
    /// reclaimed or shrunken. Three outcomes:
    ///  1. Watermark impossible vs live (>2× allocated, the pre-cc164a8 latch)
    ///     → restamp baseline immediately.
    ///  2. Second consecutive no-progress compact → the arena legitimately
    ///     grew past its watermark with nothing reclaimable; relatch baseline
    ///     so the shim's needs-compact gate stops respawning no-op compacts
    ///     forever. A real bloat case never reaches this: it shrinks and
    ///     stamps via writeIfReclaimed.
    ///  3. First no-progress compact → bump the counter, keep the watermark,
    ///     allow one more attempt (cheap guard against a shrink racing us).
    /// Threshold mirrors mcp/cckit_mcp.py:_COMPACT_STAMP_MAX_LIVE_RATIO.
    @discardableResult
    static func settleWithheldCompactStamp(cckitDir: String, waxBytesAfter: Int) throws -> Bool {
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
        if prior.noShrinkRuns >= 1 {
            print(
                "No-progress compact again (\(prior.noShrinkRuns + 1) consecutive); relatching baseline at \(waxBytesAfter) so needs-compact stops respawning."
            )
            try WaxCompactStamp.relatchBaseline(allocatedBytes: waxBytesAfter, cckitDir: cckitDir)
            return true
        }
        let runs = try WaxCompactStamp.recordNoShrinkRun(cckitDir: cckitDir)
        _ = runs
        return false
    }

    /// Take the repo-wide indexer lock (.cckit/refresh.lock) without blocking.
    /// Returns the held file descriptor, or nil when another indexing process
    /// holds it. One writer per repo regardless of trigger source (MCP shim,
    /// git hooks, human invocations): contended callers DROP, they never queue
    /// a second rebuild behind the first.
    static func tryAcquireRefreshLock(lockPath: String) -> Int32? {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
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
        // implicitly on process exit even on crash.
        guard let fd = Self.tryAcquireRefreshLock(lockPath: "\(cckitDir)/refresh.lock") else {
            print(Self.indexSkippedLine(reason: "locked"))
            throw ExitCode.success
        }
        defer { close(fd) }

        let storedEmbedderId = WaxEmbedderIdentity.storedId(cckitDir: cckitDir)
        let embedderMismatch = storedEmbedderId != WaxEmbedderIdentity.current
        let compactOnly = compact && !clean
        // Incremental indexing skips unchanged files and would leave a text-only
        // `.wax` without vectors after an embedder upgrade. Rebuild both stores.
        // `--compact` must not wipe the store it is reclaiming.
        let mustRebuild = !compactOnly && (clean || (embedderMismatch && (fm.fileExists(atPath: waxPath) || fm.fileExists(atPath: dbPath))))

        if compactOnly {
            guard fm.fileExists(atPath: dbPath), fm.fileExists(atPath: waxPath) else {
                print("Error: Index not found. Run 'cckit index .' first.")
                throw ExitCode.failure
            }
        }

        if mustRebuild {
            if embedderMismatch && !clean {
                print("Semantic embedder changed (\(storedEmbedderId ?? "none") → \(WaxEmbedderIdentity.current)); rebuilding index for vector search...")
            }
            if fm.fileExists(atPath: dbPath) {
                try fm.removeItem(atPath: dbPath)
            }
            if fm.fileExists(atPath: waxPath) {
                try fm.removeItem(atPath: waxPath)
            }
        }
        
        let db = try Database(path: dbPath)
        let bytesBeforeIndexing = Self.waxFileAllocatedBytes(at: waxPath)
        let wax = try await WaxStore(path: waxPath)
        guard await wax.isAvailable(), await wax.hasEmbeddings() else {
            print("Error: Failed to open MiniLM semantic store at \(waxPath).")
            throw ExitCode.failure
        }
        let actionOrchestrator = ActionOrchestrator(wax: wax)
        let indexer = Indexer(db: db, wax: wax)
        let absolutePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if compactOnly {
            print("Compacting Wax against SQLite symbols (no re-embed)...")
            // Frame-level truth first: what compaction CAN see.
            if let diag = try? await wax.storeDiagnostics() {
                let bloatRatio = diag.expectedLiveBytes > 0
                    ? Double(diag.allocatedBytes) / Double(diag.expectedLiveBytes)
                    : 0
                print(
                    "WaxStorage file=\(diag.fileBytes)B materialized=\(diag.allocatedBytes)B " +
                    "frames active=\(diag.activeFrameCount) deleted=\(diag.deletedFrameCount) superseded=\(diag.supersededFrameCount); " +
                    "livePayload=\(diag.liveFramePayloadBytes)B deadPayload=\(diag.deadFramePayloadBytes)B " +
                    "staleSegments=\(diag.staleSegmentBytes)B lex=\(diag.currentLexIndexBytes)B vec=\(diag.currentVecIndexBytes)B"
                )
                if bloatRatio >= 2.0 {
                    // scanned == kept with a bloated file means the dead weight
                    // is stale index segments, invisible to frame diffing.
                    print(
                        "Warning: repo.wax is \(String(format: "%.1f", bloatRatio))x its expected live size " +
                        "(\(diag.allocatedBytes)B materialized vs ~\(diag.expectedLiveBytes)B); close-time live-set rewrite below is what actually reclaims."
                    )
                }
            }
            let result = try await indexer.compactWax()
            print("Compact complete. Scanned: \(result.scanned), kept: \(result.kept), deleted: \(result.deleted)")
            // Closing the store is what triggers Wax's close-time live-set
            // rewrite (payload-level reclaim, frame-ID preserving). Measure and
            // stamp only afterwards so decisions use post-reclaim bytes.
            try await wax.close()
            let bytesAfter = Self.waxFileAllocatedBytes(at: waxPath)
            // Stamp only real reclamations; a no-shrink stamp would latch bloat
            // as the healthy watermark and hide future growth from MCP.
            var stamped = try WaxCompactStamp.writeIfReclaimed(
                cckitDir: cckitDir,
                deleted: result.deleted,
                bytesBefore: result.bytesBefore,
                bytesAfter: bytesAfter
            )
            if !stamped {
                if result.deleted > 0 {
                    print(
                        "Compaction stamp withheld: file did not shrink " +
                        "(\(result.bytesBefore) → \(bytesAfter) bytes); growth stays visible to MCP."
                    )
                } else {
                    print("Nothing to reclaim (deleted 0 frames); stamp withheld.")
                }
                // Self-heal a pre-cc164a8 latched watermark, or converge a
                // healthy-but-grown store that has nothing reclaimable.
                let restamped = try Self.settleWithheldCompactStamp(
                    cckitDir: cckitDir,
                    waxBytesAfter: bytesAfter
                )
                if restamped { stamped = true }
            }
            let measured = WaxCompactResult(
                scanned: result.scanned,
                deleted: result.deleted,
                kept: result.kept,
                bytesBefore: result.bytesBefore,
                bytesAfter: bytesAfter
            )
            print(Self.machineReadableLine(for: measured, stamped: stamped))
            let duration = Int(Date().timeIntervalSince(startTime) * 1000)
            let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
            try await actionOrchestrator.recordCLIAction(command: fullCommand, toolName: "index", durationMs: duration)
            return
        }

        if !excludeFolder.isEmpty || !includeFolder.isEmpty {
            var settings = ProjectSettings.load(projectRoot: absolutePath)
            settings.excludedFolders = Array(Set(settings.excludedFolders + excludeFolder)).sorted()
            settings.includedFolders = Array(Set(settings.includedFolders + includeFolder)).sorted()
            try settings.save(projectRoot: absolutePath)
        }
        
        print("Indexing \(path)...")
        let stdoutIsTTY = isatty(STDOUT_FILENO) != 0

        // Circuit breaker, phase 1: force a live-set reclaim when the arena is
        // far past its expected live size. Never verdicts here — reclaimed
        // bytes only appear at close. Comparison uses allocated (materialized)
        // bytes; Wax preallocates arenas sparsely.
        if !mustRebuild {
            try await enforceWaxBloatBreaker(wax, cckitDir: cckitDir)
        } else {
            Self.clearBreachMarker(cckitDir: cckitDir)
        }

        let compacted = try await indexer.index(
            at: path,
            include: include,
            exclude: exclude,
            includeBuildScripts: includeBuildScripts,
            includeGenerated: includeGenerated,
            delegate: CommandLineProgressDelegate(
                emitProgress: InteractiveProgress.shouldEmitTTYProgress(stdoutIsTTY: stdoutIsTTY)
            )
        )

        try WaxEmbedderIdentity.writeSidecar(cckitDir: cckitDir)
        if let stamp = IndexFreshness.captureStamp(repoRoot: absolutePath) {
            try stamp.write(cckitDir: cckitDir)
        } else if let stamp = IndexFreshness.captureStamp(repoRoot: path) {
            // Fall back when absolutePath isn't a git root but `path` is cwd.
            try stamp.write(cckitDir: cckitDir)
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(command: fullCommand, toolName: "index", durationMs: duration)

        // Snapshot the breaker's inputs BEFORE close: close() releases the
        // file handle, so post-close diagnostics are impossible. The live set
        // is final at this point; only promotion changes materialized bytes.
        let breakerSnapshot: StoreDiagnostics? = !mustRebuild
            ? try? await wax.storeDiagnostics()
            : nil

        // Closing may trigger Wax's close-time live-set rewrite; measure and
        // stamp against post-close bytes so decisions reflect reality.
        try await wax.close()
        let bytesAfterIndexing = Self.waxFileAllocatedBytes(at: waxPath)

        // Circuit breaker, phase 2: judge this run's forced reclaim against
        // the promoted file and arm (or clear) the fail-fast marker for the
        // NEXT invocation.
        if let snapshot = breakerSnapshot {
            Self.settleWaxBreakerVerdict(
                cckitDir: cckitDir,
                snapshot: snapshot,
                materializedAfterClose: Self.waxFileAllocatedBytes(at: waxPath)
            )
        }

        // Baseline stamps are only valid for stores built by construction
        // (--clean / embedder rebuild), where every byte is live. On the
        // incremental path a no-shrink stamp would latch bloat as healthy.
        let stamped: Bool
        if mustRebuild {
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
                bytesAfter: bytesAfterIndexing
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
