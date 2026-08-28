import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore

final class WaxDeltaTests: XCTestCase {
    var tempDir: URL!
    var cckitDir: URL!
    var wax: WaxStore!
    var db: CodeContextKitStorage.Database!
    var indexer: Indexer!

    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        cckitDir = tempDir.appendingPathComponent(".cckit")
        try FileManager.default.createDirectory(at: cckitDir, withIntermediateDirectories: true)
        db = try CodeContextKitStorage.Database(path: cckitDir.appendingPathComponent("index.sqlite").path)
        wax = try await WaxStore(path: cckitDir.appendingPathComponent("repo.wax").path)
        indexer = Indexer(db: db, wax: wax)
        try "struct Alpha { func one() -> Int { 1 } }".write(
            to: tempDir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        try "struct Beta { func two() -> Int { 2 } }".write(
            to: tempDir.appendingPathComponent("Beta.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? await wax.close()
        wax = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("CCKIT_WAX_DELTA_MAX_FILES")
        unsetenv("CCKIT_WAX_DELTA_MAX_GROWTH")
        try await super.tearDown()
    }

    /// Full index + close + baseline stamp, then a fresh store handle — the
    /// exact state a CLI `index` run leaves behind.
    func primeIndexAndStamp() async throws {
        let first = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)
        XCTAssertTrue(first.rebuiltWax, "First index has no stamp and must rebuild")
        try await wax.close()
        try WaxCompactStamp.writeBaseline(cckitDir: cckitDir.path)
        wax = try await WaxStore(path: cckitDir.appendingPathComponent("repo.wax").path)
        indexer = Indexer(db: db, wax: wax)
    }

    // MARK: - Policy matrix

    func testPolicyHappyPath() {
        XCTAssertTrue(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_004_096, arenaFrameCount: 10, keepSetMandateCount: 10))
    }

    func testPolicyRefusesForcedRebuild() {
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: true, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_000_000, arenaFrameCount: 10, keepSetMandateCount: 10))
    }

    func testPolicyRefusesWhenCeilingExceededOrDisabled() {
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 33, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_000_000, arenaFrameCount: 10, keepSetMandateCount: 10,
            maxFiles: 32))
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_000_000, arenaFrameCount: 10, keepSetMandateCount: 10,
            maxFiles: 0))
    }

    func testPolicyRefusesWithoutStamp() {
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 0,
            arenaAllocatedBytes: 500_000, arenaFrameCount: 10, keepSetMandateCount: 10))
    }

    func testPolicyRefusesSilentEmptyArena() {
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_000_000, arenaFrameCount: 0, keepSetMandateCount: 10))
        // A legitimately empty corpus (no mandates) is fine.
        XCTAssertTrue(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_000_000, arenaFrameCount: 0, keepSetMandateCount: 0))
    }

    func testPolicyRefusesTruncatedAndBloatedArenas() {
        // 90% shrink floor: gutted arena must rebuild, not append.
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 800_000, arenaFrameCount: 10, keepSetMandateCount: 10))
        // Growth past margin + allowance: leaks must be reclaimed by a rebuild.
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 1_000_000,
            arenaAllocatedBytes: 1_200_000, arenaFrameCount: 10, keepSetMandateCount: 10,
            maxGrowth: 0.10, allowanceBytes: 0))
    }

    func testPolicyAllowanceToleratesFixedSegmentChurnOnSmallArenas() {
        // Measured Wax behavior: one delta appends ~278KB of index-segment
        // bytes regardless of arena size. A 63% jump on a 0.4MB arena is a
        // normal incremental append, not leak — the absolute allowance keeps
        // the incremental path alive on small repos.
        XCTAssertTrue(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 442_368,
            arenaAllocatedBytes: 720_896, arenaFrameCount: 80, keepSetMandateCount: 80))
        // But unbounded leak still rebuilds: past margin + allowance.
        XCTAssertFalse(WaxDeltaPolicy.isEligible(
            forceRebuild: false, deltaFileCount: 1, stampAllocatedBytes: 442_368,
            arenaAllocatedBytes: 442_368 + 17_000_000, arenaFrameCount: 80, keepSetMandateCount: 80))
    }

    // MARK: - Delta path integration

    func testSmallDeltaAppendsInsteadOfRebuilding() async throws {
        try await primeIndexAndStamp()
        let framesBefore = await wax.frameCount()
        let mandatesBefore = try db.waxMandateCount()

        try "struct Alpha { func one() -> Int { 111 } }".write(
            to: tempDir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        let second = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)

        XCTAssertTrue(second.deltaApplied, "One changed file must take the append path")
        XCTAssertFalse(second.rebuiltWax)
        XCTAssertEqual(second.updated, 1)
        XCTAssertEqual(second.skipped, 1, "The unchanged file must keep its SQLite fast-skip")

        let framesAfter = await wax.frameCount()
        XCTAssertGreaterThan(framesAfter, framesBefore, "Append path adds frames; stale twins leak until rebuild")
        XCTAssertEqual(try db.waxMandateCount(), mandatesBefore, "Mandate rows replace, not accumulate")

        let alpha = try db.getSymbols(path: "Alpha.swift").first
        XCTAssertEqual(alpha?.name, "Alpha")
        XCTAssertEqual(try db.uncoveredWaxFilePaths(), [], "Delta run must leave coverage complete")

        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")
        let hits = try await wax.search("alpha one function", limit: 10)
        XCTAssertTrue(hits.contains { $0.symbol == "Alpha" }, "Fresh document must be retrievable")
    }

    func testCeilingExceededFallsBackToFullRebuild() async throws {
        try await primeIndexAndStamp()
        setenv("CCKIT_WAX_DELTA_MAX_FILES", "1", 1)
        defer { unsetenv("CCKIT_WAX_DELTA_MAX_FILES") }

        try "struct Alpha { func one() -> Int { 111 } }".write(
            to: tempDir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        try "struct Beta { func two() -> Int { 222 } }".write(
            to: tempDir.appendingPathComponent("Beta.swift"), atomically: true, encoding: .utf8)
        let result = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)

        XCTAssertTrue(result.rebuiltWax, "Delta above the ceiling must replace the arena")
        XCTAssertFalse(result.deltaApplied)
        XCTAssertEqual(result.updated, 2)
    }

    func testGrowthPastMarginFallsBackToFullRebuild() async throws {
        try await primeIndexAndStamp()
        setenv("CCKIT_WAX_DELTA_MAX_GROWTH", "0", 1)
        setenv("CCKIT_WAX_DELTA_ALLOWANCE_BYTES", "0", 1)
        defer {
            unsetenv("CCKIT_WAX_DELTA_MAX_GROWTH")
            unsetenv("CCKIT_WAX_DELTA_ALLOWANCE_BYTES")
        }

        // Run 2 appends (margin applies to the NEXT run's start allocation).
        try "struct Alpha { func one() -> Int { 111 } }".write(
            to: tempDir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        let second = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)
        XCTAssertTrue(second.deltaApplied, "Run 2 appends; leak accounting starts")

        let stampBytes = WaxCompactStamp.readWatermark(cckitDir: cckitDir.path)?.waxBytes ?? 0
        let allocatedNow = await wax.allocatedBytes()
        XCTAssertGreaterThan(allocatedNow, stampBytes, "The append must grow the arena past the stale baseline")

        // Run 3 sees the leaked growth and must reclaim via a full rebuild.
        let third = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)
        XCTAssertTrue(third.rebuiltWax, "Growth past the margin must trigger a reclaiming rebuild")
        XCTAssertFalse(third.deltaApplied)
    }

    func testSilentEmptyArenaRebuildsAndGateFaultsBeforeRepair() async throws {
        try await primeIndexAndStamp()
        let waxPath = cckitDir.appendingPathComponent("repo.wax").path

        // The poison state: openable-but-empty arena against a populated keep-set.
        try await wax.close()
        try FileManager.default.removeItem(atPath: waxPath)
        wax = try await WaxStore(path: waxPath)
        indexer = Indexer(db: db, wax: wax)

        let report = await WaxReadGate.evaluate(waxPath: waxPath, cckitDir: cckitDir.path, db: db, wax: wax)
        guard case .emptyArena(let mandates)? = report.hardFault else {
            return XCTFail("Expected emptyArena fault, got \(String(describing: report.hardFault))")
        }
        XCTAssertGreaterThan(mandates, 0)

        try "struct Alpha { func one() -> Int { 111 } }".write(
            to: tempDir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        let result = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)
        XCTAssertTrue(result.rebuiltWax, "Silent-empty arena must be repaired by a full rebuild, not appended to")
        let framesRepaired = await wax.frameCount()
        XCTAssertGreaterThan(framesRepaired, 0, "Repaired arena must hold documents again")
    }

    func testRemovedAndAddedFilesTakeDeltaPath() async throws {
        try await primeIndexAndStamp()
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Beta.swift"))
        try "struct Gamma { func three() -> Int { 3 } }".write(
            to: tempDir.appendingPathComponent("Gamma.swift"), atomically: true, encoding: .utf8)
        let result = try await indexer.index(at: tempDir.path, cckitDir: cckitDir.path)

        XCTAssertTrue(result.deltaApplied)
        XCTAssertFalse(result.rebuiltWax)
        XCTAssertNil(try db.getFile(path: "Beta.swift"), "Removed file must leave the keep-set")
        XCTAssertNotNil(try db.getFile(path: "Gamma.swift"))
        XCTAssertEqual(try db.uncoveredWaxFilePaths(), [])
    }
}
