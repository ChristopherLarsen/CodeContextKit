import XCTest
import Foundation
@testable import CodeContextKitContext

/// Regression for the shipped `map` / `--changed` deadlock: MapBaseline.git
/// called waitUntilExit() before readDataToEndOfFile(), so any diff larger
/// than the ~64 KB pipe buffer blocked git on write and cckit on wait —
/// forever. Agent definitions had to instruct every agent to never call map.
final class MapBaselineDeadlockTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-mapbase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try git(["config", "user.email", "test@test"])
        try git(["config", "user.name", "test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        // The same drain-before-wait rule this test exists to enforce.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `changedPaths` over a diff whose output exceeds the pipe buffer must
    /// return, not hang. 3000 changed paths ≈ 100 KB of `--name-only` output,
    /// well past the 64 KB pipe buffer that deadlocked the shipped build
    /// (this repo's own diff is 148 KB).
    func testChangedPathsSurvivesOutputLargerThanPipeBuffer() async throws {
        let fileCount = 3000
        for i in 0..<fileCount {
            try "struct F\(i) {}\n".write(
                to: dir.appendingPathComponent("F\(i).swift"), atomically: true, encoding: .utf8)
        }
        try git(["add", "."])
        try git(["commit", "-q", "-m", "base"])
        for i in 0..<fileCount {
            try "struct F\(i) { let changed = \(i) }\n".write(
                to: dir.appendingPathComponent("F\(i).swift"), atomically: true, encoding: .utf8)
        }

        // Race against a watchdog so a regression fails loudly instead of
        // wedging the whole suite (the shipped deadlock was permanent).
        let dirPath = dir.path
        let task = Task.detached {
            MapBaseline.changedPaths(repoRoot: dirPath, base: "HEAD")
        }
        let completed = await withTaskGroup(of: Set<String>?.self) { group -> Set<String>? in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let changed = completed else {
            return XCTFail("changedPaths hung on a >64KB diff output — the pipe-buffer deadlock is back")
        }
        XCTAssertEqual(changed.count, fileCount)
    }
}
