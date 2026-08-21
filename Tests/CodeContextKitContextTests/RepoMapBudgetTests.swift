import XCTest
import Foundation
import CodeContextKitCore
import CodeContextKitRetrieval
@testable import CodeContextKitContext
@testable import CodeContextKitStorage

final class InteractiveProgressTests: XCTestCase {
    func testMapProgressSilentWhenNotVerboseOrNotTTY() {
        XCTAssertFalse(InteractiveProgress.shouldEmit(verbose: false, stdoutIsTTY: true))
        XCTAssertFalse(InteractiveProgress.shouldEmit(verbose: true, stdoutIsTTY: false))
        XCTAssertFalse(InteractiveProgress.shouldEmit(verbose: false, stdoutIsTTY: false))
        XCTAssertTrue(InteractiveProgress.shouldEmit(verbose: true, stdoutIsTTY: true))
    }

    func testIndexProgressSilentWhenNotTTY() {
        XCTAssertFalse(InteractiveProgress.shouldEmitTTYProgress(stdoutIsTTY: false))
        XCTAssertTrue(InteractiveProgress.shouldEmitTTYProgress(stdoutIsTTY: true))
    }

    func testRankingLineFormat() {
        let line = InteractiveProgress.rankingLine(
            completed: 50,
            total: 200,
            currentFile: "App/Settings/SettingsView.swift"
        )
        XCTAssertTrue(line.contains("Ranking symbols: 25% [50/200] SettingsView.swift"))
        XCTAssertTrue(line.hasPrefix("\r"))
    }
}

final class RepoMapAssemblerTests: XCTestCase {
    func testTrimsToCharBudgetAndHeaderMatches() async {
        let chunks = (0..<40).map { "chunk-\($0)-" + String(repeating: "x", count: 50) }
        let budget = 400
        let map = await RepoMapAssembler.assemble(
            chunks: chunks,
            budget: budget,
            counter: { text in text.count }
        )
        XCTAssertLessThanOrEqual(map.count, budget)
        XCTAssertTrue(map.hasPrefix("# Repository Map"))
        XCTAssertFalse(map.contains("Ranking symbols"))
        if let match = map.firstMatch(of: /Tokens: (\d+)\/(\d+)/),
           let reported = Int(match.1),
           let cap = Int(match.2) {
            XCTAssertEqual(cap, budget)
            XCTAssertEqual(reported, map.count)
        } else {
            XCTFail("Missing token header")
        }
    }

    func testEmptyChunksStillEmitsHeader() async {
        let map = await RepoMapAssembler.assemble(
            chunks: [],
            budget: 50,
            counter: { text in text.count }
        )
        XCTAssertTrue(map.contains("# Repository Map"))
        XCTAssertFalse(map.contains("Ranking symbols"))
    }
}

final class RepoMapBudgetTests: XCTestCase {
    var db: Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var fixtureURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        db = try Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        fixtureURL = currentDir.appendingPathComponent("Tests/Fixtures/PackSliceProject")
    }

    func testRealTokenizerHonorsBudgetsAndOmitsProgressSpam() async throws {
        try await indexer.index(at: fixtureURL.path)
        let wax = self.wax!
        let builder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
        for budget in [500, 1000, 4096, 16000] {
            let map = try await builder.buildMap(budget: budget)
            let used = await wax.countTokens(map)
            XCTAssertLessThanOrEqual(used, budget, "budget \(budget): used \(used)")
            XCTAssertFalse(map.contains("Ranking symbols"), "map stdout must not contain progress spam")
            XCTAssertTrue(map.hasPrefix("# Repository Map"), map.prefix(80).description)
            if let match = map.firstMatch(of: /Tokens: (\d+)\/(\d+)/),
               let reported = Int(match.1) {
                let delta = abs(Double(reported - used) / Double(max(used, 1)))
                XCTAssertLessThanOrEqual(
                    delta,
                    0.02,
                    "header \(reported) vs real \(used) for budget \(budget)"
                )
            } else {
                XCTFail("Missing token header for budget \(budget)")
            }
        }
    }

    func testBuildMapFinishesWithoutEmbedding() async throws {
        try await indexer.index(at: fixtureURL.path)
        let estimator = TokenEstimator.shared
        let builder = RepoMapBuilder(db: db, counter: { text in estimator.estimate(text) })
        let start = Date()
        let map = try await builder.buildMap(budget: 1000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(map.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "map must not embed symbols; took \(elapsed)s")
    }
}

final class MapBaselineTests: XCTestCase {
    func testChangedPathsRespectsDiff() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-map-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("Beta.swift"), atomically: true, encoding: .utf8)
        try runGit(dir, ["init"])
        try runGit(dir, ["config", "user.email", "test@example.com"])
        try runGit(dir, ["config", "user.name", "Test"])
        try runGit(dir, ["add", "."])
        try runGit(dir, ["commit", "-m", "init"])

        try "changed".write(to: dir.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        let changed = MapBaseline.changedPaths(repoRoot: dir.path, base: "HEAD")
        XCTAssertTrue(changed.contains("Alpha.swift"))
        XCTAssertFalse(changed.contains("Beta.swift"))

        try? FileManager.default.removeItem(at: dir)
    }

    private func runGit(_ dir: URL, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }
}

final class ActionCallerTests: XCTestCase {
    func testDefaultsToCli() {
        XCTAssertEqual(ActionCaller.recordType(environment: [:]), "cli")
        XCTAssertEqual(ActionCaller.recordType(environment: ["CCKIT_CALLER": "CLI"]), "cli")
    }

    func testMcpCaller() {
        XCTAssertEqual(ActionCaller.recordType(environment: ["CCKIT_CALLER": "mcp"]), "mcp")
        XCTAssertEqual(ActionCaller.recordType(environment: ["CCKIT_CALLER": " MCP "]), "mcp")
    }

    func testSessionIdDecodeIgnored() throws {
        let json = """
        {"id":1,"prompt":"cckit map","toolName":"map","type":"cli","tokensUsed":10,"durationMs":1,"status":"completed","timestamp":"2026-08-13T12:00:00Z","sessionId":"old"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ActionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.type, "cli")
    }

    func testMcpRowRoundTrip() throws {
        let record = ActionRecord(
            id: 2,
            prompt: "cckit map",
            toolName: "map",
            type: "mcp",
            tokensUsed: 100,
            durationMs: 5,
            status: "completed"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("sessionId"))
        XCTAssertFalse(text.contains("baselineTokens"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ActionRecord.self, from: data)
        XCTAssertEqual(decoded.type, "mcp")
    }
}
