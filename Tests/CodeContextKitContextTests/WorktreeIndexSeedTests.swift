import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitRetrieval

final class WorktreeIndexSeedTests: XCTestCase {
    var tempDir: URL!
    var main: String!
    var worktree: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-seed-\(UUID().uuidString)", isDirectory: true)
        main = tempDir.appendingPathComponent("main").path
        worktree = tempDir.appendingPathComponent("wt").path
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try "struct A {}\n".write(toFile: main + "/A.swift", atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], cwd: main)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "add", "A.swift"], cwd: main)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], cwd: main)
        try git(["worktree", "add", "-q", "-b", "feature", worktree], cwd: main)
        try writeMainIndex(embedder: WaxEmbedderIdentity.current)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSeedsUnindexedLinkedWorktree() throws {
        let outcome = WorktreeIndexSeed.seedIfNeeded(repoRoot: worktree, lockWait: 0)
        guard case .seeded(_, let files) = outcome else {
            return XCTFail("expected seed, got \(outcome)")
        }
        XCTAssertTrue(files.contains("index.sqlite"))
        XCTAssertTrue(files.contains("repo.wax"))
        XCTAssertEqual(try String(contentsOfFile: worktree + "/.cckit/index.sqlite", encoding: .utf8), "db")
        // Source-only state never travels.
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + "/.cckit/action_history.jsonl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree + "/.cckit/index.sqlite.seed-tmp"))
    }

    func testSkipsWhenWorktreeAlreadyIndexed() throws {
        try FileManager.default.createDirectory(atPath: worktree + "/.cckit", withIntermediateDirectories: true)
        try "own".write(toFile: worktree + "/.cckit/index.sqlite", atomically: true, encoding: .utf8)
        XCTAssertEqual(
            WorktreeIndexSeed.seedIfNeeded(repoRoot: worktree, lockWait: 0),
            .skipped(reason: "already_indexed")
        )
        XCTAssertEqual(try String(contentsOfFile: worktree + "/.cckit/index.sqlite", encoding: .utf8), "own")
    }

    func testSkipsMainCheckout() throws {
        try FileManager.default.removeItem(atPath: main + "/.cckit")
        XCTAssertEqual(
            WorktreeIndexSeed.seedIfNeeded(repoRoot: main, lockWait: 0),
            .skipped(reason: "not_linked_worktree")
        )
    }

    func testSkipsOnEmbedderMismatch() throws {
        try writeMainIndex(embedder: "Wax.BuiltIn.miniLM.v1")
        XCTAssertEqual(
            WorktreeIndexSeed.seedIfNeeded(repoRoot: worktree, lockWait: 0),
            .skipped(reason: "source_embedder_mismatch")
        )
        XCTAssertTrue(WorktreeIndexSeed.needsSeed(repoRoot: worktree))
    }

    func testSkipsWhileSourceIsLocked() throws {
        let lease = try XCTUnwrap(RefreshLock.tryAcquire(lockPath: main + "/.cckit/refresh.lock"))
        defer { lease.release() }
        XCTAssertEqual(
            WorktreeIndexSeed.seedIfNeeded(repoRoot: worktree, lockWait: 0),
            .skipped(reason: "source_locked")
        )
    }

    private func writeMainIndex(embedder: String) throws {
        let dir = main + "/.cckit"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "db".write(toFile: dir + "/index.sqlite", atomically: true, encoding: .utf8)
        try "wax".write(toFile: dir + "/repo.wax", atomically: true, encoding: .utf8)
        try "{}".write(toFile: dir + "/index-stamp.json", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: dir + "/action_history.jsonl", atomically: true, encoding: .utf8)
        try embedder.write(toFile: dir + "/" + WaxEmbedderIdentity.sidecarFileName, atomically: true, encoding: .utf8)
    }

    private func git(_ args: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }
}
