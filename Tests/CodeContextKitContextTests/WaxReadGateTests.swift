import XCTest
import Foundation
@testable import CodeContextKitRetrieval
@testable import CodeContextKitStorage
@testable import CodeContextKitContext

final class WaxReadGateTests: XCTestCase {
    var tempDir: URL!
    var cckitDir: URL!
    var waxPath: String!
    var dbPath: String!
    var wax: WaxStore!
    var db: CodeContextKitStorage.Database!

    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        cckitDir = tempDir.appendingPathComponent(".cckit")
        try FileManager.default.createDirectory(at: cckitDir, withIntermediateDirectories: true)
        waxPath = cckitDir.appendingPathComponent("repo.wax").path
        dbPath = cckitDir.appendingPathComponent("index.sqlite").path
        db = try CodeContextKitStorage.Database(path: dbPath)
        wax = try await WaxStore(path: waxPath)
    }

    override func tearDown() async throws {
        try? await wax.close()
        wax = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Truncation policy (request 2)

    func testTruncationFiresAtIncidentRatio() {
        // The reported state: arena at ~35.8MB vs ~127.8MB last-known-complete.
        let fault = WaxReadGate.hardFault(
            allocatedBytes: 35_786_752,
            expectedAllocatedBytes: 127_770_624,
            uncoveredExistingPaths: []
        )
        guard case .truncatedArena(let expected, let actual)? = fault else {
            return XCTFail("Expected truncation fault, got \(String(describing: fault))")
        }
        XCTAssertEqual(expected, 127_770_624)
        XCTAssertEqual(actual, 35_786_752)
    }

    func testTruncationIgnoresOrdinaryChurn() {
        XCTAssertNil(WaxReadGate.hardFault(
            allocatedBytes: 120_000_000,
            expectedAllocatedBytes: 127_770_624,
            uncoveredExistingPaths: []
        ))
    }

    func testTruncationIgnoresYoungAndTinyStores() {
        // Stamp under the floor: no expectation worth enforcing.
        XCTAssertNil(WaxReadGate.hardFault(
            allocatedBytes: 100_000,
            expectedAllocatedBytes: 400_000,
            uncoveredExistingPaths: []
        ))
    }

    func testTruncationIgnoresImpossibleLatchedWatermark() {
        // A pre-cc164a8 latch (observed 1388x) is a stamping bug, not truncation.
        XCTAssertNil(WaxReadGate.hardFault(
            allocatedBytes: 198_000_000,
            expectedAllocatedBytes: 275_000_000_000,
            uncoveredExistingPaths: []
        ))
    }

    // MARK: - Rebuild coverage (request 4)

    func testRebuildIncompleteFiresOnUncoveredExistingPaths() {
        let fault = WaxReadGate.hardFault(
            allocatedBytes: 127_770_624,
            expectedAllocatedBytes: 127_770_624,
            uncoveredExistingPaths: ["/repo/Sources/A.swift", "/repo/Sources/B.swift"]
        )
        guard case .rebuildIncomplete(let count, let sample)? = fault else {
            return XCTFail("Expected rebuild-incomplete fault, got \(String(describing: fault))")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(sample.first, "/repo/Sources/A.swift")
    }

    func testTruncationWinsOverIncompleteRebuild() {
        let fault = WaxReadGate.hardFault(
            allocatedBytes: 35_786_752,
            expectedAllocatedBytes: 127_770_624,
            uncoveredExistingPaths: ["/repo/Sources/A.swift"]
        )
        guard case .truncatedArena? = fault else {
            return XCTFail("Expected truncation to take precedence, got \(String(describing: fault))")
        }
    }

    // MARK: - SQLite keep-set queries

    func testUncoveredAndMandateQueries() throws {
        let fileA = try db.saveFile(path: "A.swift", language: "swift", sha256: "a", sizeBytes: 10, modifiedAt: nil)
        let fileB = try db.saveFile(path: "B.swift", language: "swift", sha256: "b", sizeBytes: 10, modifiedAt: nil)

        var uncovered = try db.uncoveredWaxFilePaths()
        XCTAssertEqual(Set(uncovered), ["A.swift", "B.swift"])
        XCTAssertEqual(try db.waxMandateCount(), 0)

        try db.saveWaxFrames(fileId: fileA, mandate: "mandate1", frameIDs: [])
        try db.markWaxCoverage(fileId: fileB)

        uncovered = try db.uncoveredWaxFilePaths()
        XCTAssertEqual(uncovered, [])
        XCTAssertEqual(try db.waxMandateCount(), 1)
    }

    // MARK: - Full evaluation (requests 1, 2, 4)

    func testEvaluateWarnsWithArmedMarker() async throws {
        let marker: [String: Any] = [
            "allocatedBytes": 8_816_898_048,
            "expectedLiveBytes": 107_479_040,
            "reclaimableBytes": 8_709_419_008,
            "factor": 8.0,
        ]
        let markerData = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try markerData.write(to: cckitDir.appendingPathComponent("wax-breach-marker.json"))

        let report = await WaxReadGate.evaluate(waxPath: waxPath, cckitDir: cckitDir.path, db: db, wax: wax)
        XCTAssertNil(report.hardFault)
        let warning = try XCTUnwrap(report.breachWarning)
        XCTAssertTrue(warning.contains("8816898048"), warning)
        XCTAssertTrue(warning.contains("107479040"), warning)
        XCTAssertTrue(warning.contains("--clean"), warning)
        XCTAssertTrue(report.isDegraded)
    }

    func testEvaluateDetectsTruncatedArenaViaStamp() async throws {
        // Stamp from the last complete arena; the live arena file holds 2MB.
        // A separate path keeps the setUp-opened arena untouched.
        let stamp: [String: Any] = ["waxBytes": 12_000_000, "deletedFrames": 0, "noShrinkRuns": 0]
        let stampData = try JSONSerialization.data(withJSONObject: stamp, options: [.sortedKeys])
        try stampData.write(to: cckitDir.appendingPathComponent("wax-compact-stamp.json"))

        let truncatedPath = tempDir.appendingPathComponent("truncated.wax").path
        try Data(count: 2_000_000).write(to: URL(fileURLWithPath: truncatedPath))
        let truncatedWax = try await WaxStore(path: truncatedPath)
        defer { Task { try? await truncatedWax.close() } }

        let report = await WaxReadGate.evaluate(
            waxPath: truncatedPath,
            cckitDir: cckitDir.path,
            db: db,
            wax: truncatedWax
        )
        guard case .truncatedArena? = report.hardFault else {
            return XCTFail("Expected truncation fault, got \(String(describing: report.hardFault))")
        }
    }

    func testEvaluateHealthyWhenNoEvidence() async throws {
        let report = await WaxReadGate.evaluate(waxPath: waxPath, cckitDir: cckitDir.path, db: db, wax: wax)
        XCTAssertNil(report.hardFault)
        XCTAssertNil(report.breachWarning)
        XCTAssertFalse(report.isDegraded)
    }

    // MARK: - Indexer coverage contract (request 4 root fix)

    func testUnreadableFileDoesNotLeaveCoverageResidue() async throws {
        let indexer = Indexer(db: db, wax: wax)
        let unreadable = tempDir.appendingPathComponent("Unreadable.swift")
        try "struct Sealed { }".write(to: unreadable, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        XCTAssertEqual(try db.uncoveredWaxFilePaths(), [])

        // Make the file unreadable, then force a rebuild via a second file.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadable.path
        )
        let mutable = tempDir.appendingPathComponent("Mutable.swift")
        try "struct First { }".write(to: mutable, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        try "struct Second { }".write(to: mutable, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)

        let uncoveredExisting = try db.uncoveredWaxFilePaths()
            .filter { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(uncoveredExisting, [], "An unreadable file must be marked considered, not left uncovered forever")

        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: unreadable.path
        )
    }

    // MARK: - Packer threading (request 3)

    func testPackResultCarriesSemanticFillTelemetry() async throws {
        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")

        let fileURL = tempDir.appendingPathComponent("Decoder.swift")
        try """
        /// Decodes the incoming telemetry payload and normalizes units.
        struct PayloadDecoder {
            func decode(_ raw: String) -> Int { raw.count }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let indexer = Indexer(db: db, wax: wax)
        try await indexer.index(at: tempDir.path)

        let packer = ContextPacker(db: db, wax: wax, rootPath: tempDir.path)
        let prose = try await packer.pack(task: "normalize and decode telemetry payloads", budget: 2000)
        XCTAssertTrue(prose.waxFillRan, "Prose tasks must run the semantic fill")
        XCTAssertGreaterThan(prose.waxHitCount, 0, "The single indexed document should be retrievable")
        XCTAssertGreaterThanOrEqual(prose.primaryCount, 1)

        let identifierOnly = try await packer.pack(task: "PayloadDecoder", budget: 2000)
        XCTAssertFalse(identifierOnly.waxFillRan, "Identifier-only tasks skip the semantic fill")
        XCTAssertEqual(identifierOnly.waxHitCount, 0)
    }
}
