import XCTest
import Foundation
@testable import CodeContextKitContext

final class IndexSwapTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// First index: no live file yet — the staged build moves into place.
    func testSwapWithNoLiveFile() throws {
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "new-db".write(to: staging.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)

        try IndexSwap.swapBuildIntoPlace(
            cckitDir: dir.path,
            stagingDir: staging.path,
            dbPath: dir.appendingPathComponent("index.sqlite").path,
            waxPath: dir.appendingPathComponent("repo.wax").path,
            includeWax: false
        )

        let live = try String(contentsOf: dir.appendingPathComponent("index.sqlite"), encoding: .utf8)
        XCTAssertEqual(live, "new-db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "staging must be cleaned")
    }

    /// The core snapshot-rebuild guarantee: the live db and arena are replaced
    /// in one pass, staging (now holding the retired copies) is removed, and a
    /// live WAL sidecar of the retired db is not left behind to be replayed
    /// onto the new database.
    func testSwapReplacesLiveDbAndWax() throws {
        try "old-db".write(to: dir.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)
        try "old-wax".write(to: dir.appendingPathComponent("repo.wax"), atomically: true, encoding: .utf8)
        try "retired-wal".write(to: dir.appendingPathComponent("index.sqlite-wal"), atomically: true, encoding: .utf8)

        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "new-db".write(to: staging.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)
        try "new-wax".write(to: staging.appendingPathComponent("repo.wax"), atomically: true, encoding: .utf8)

        try IndexSwap.swapBuildIntoPlace(
            cckitDir: dir.path,
            stagingDir: staging.path,
            dbPath: dir.appendingPathComponent("index.sqlite").path,
            waxPath: dir.appendingPathComponent("repo.wax").path,
            includeWax: true
        )

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("index.sqlite"), encoding: .utf8), "new-db")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("repo.wax"), encoding: .utf8), "new-wax")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite-wal").path),
            "retired db WAL must never be replayed onto the swapped-in db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// Lexical rebuilds swap only the db; the untouched arena stays live.
    func testSwapKeepsWaxWhenLexical() throws {
        try "old-db".write(to: dir.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)
        try "untouched-wax".write(to: dir.appendingPathComponent("repo.wax"), atomically: true, encoding: .utf8)

        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "new-db".write(to: staging.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)

        try IndexSwap.swapBuildIntoPlace(
            cckitDir: dir.path,
            stagingDir: staging.path,
            dbPath: dir.appendingPathComponent("index.sqlite").path,
            waxPath: dir.appendingPathComponent("repo.wax").path,
            includeWax: false
        )

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("repo.wax"), encoding: .utf8), "untouched-wax")
    }

    func testSwapFailsCleanlyWithoutStagedDb() throws {
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "old-db".write(to: dir.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try IndexSwap.swapBuildIntoPlace(
            cckitDir: dir.path,
            stagingDir: staging.path,
            dbPath: dir.appendingPathComponent("index.sqlite").path,
            waxPath: dir.appendingPathComponent("repo.wax").path,
            includeWax: false
        )) { error in
            XCTAssertEqual(error as? IndexSwap.SwapError, .stagedBuildMissing(path: staging.appendingPathComponent("index.sqlite").path))
        }
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("index.sqlite"), encoding: .utf8),
            "old-db",
            "a failed swap must leave the live index untouched")
    }

    /// A crashed fallback (retire-then-move) leaves `retired-*` residue that
    /// the next successful swap must clean.
    func testSwapRemovesCrashedFallbackResidue() throws {
        let retired = dir.appendingPathComponent("retired-stale")
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        try "junk".write(to: retired.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)

        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "new-db".write(to: staging.appendingPathComponent("index.sqlite"), atomically: true, encoding: .utf8)

        try IndexSwap.swapBuildIntoPlace(
            cckitDir: dir.path,
            stagingDir: staging.path,
            dbPath: dir.appendingPathComponent("index.sqlite").path,
            waxPath: dir.appendingPathComponent("repo.wax").path,
            includeWax: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }
}
