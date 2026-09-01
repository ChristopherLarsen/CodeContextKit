import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitCore

final class LexicalBaselineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-rgbase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var rgAvailable: Bool {
        ["rg", "/opt/homebrew/bin/rg", "/usr/local/bin/rg"].contains { tool in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = [tool]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        } || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rg")
    }

    func testBaselineCountsSourceNotLedger() throws {
        try XCTSkipUnless(rgAvailable, "ripgrep required")
        try "let Needly = 1\nlet other = Needly + 1\n".write(
            to: dir.appendingPathComponent("Source.swift"), atomically: true, encoding: .utf8)
        // The ledger's own stored prompts embed past search terms; without the
        // .cckit exclusion the baseline would count the ledger counting itself.
        let cckit = dir.appendingPathComponent(".cckit")
        try FileManager.default.createDirectory(at: cckit, withIntermediateDirectories: true)
        let noise = String(repeating: "Needly ", count: 5000)
        try noise.write(to: cckit.appendingPathComponent("action_history.jsonl"), atomically: true, encoding: .utf8)

        let baseline = LexicalBaseline.tokens(for: "Needly", repoRoot: dir.path)
        XCTAssertGreaterThan(baseline, 0, "source hits must be measured")
        let twoHits = LexicalBaseline.tokens(for: "other", repoRoot: dir.path)
        XCTAssertGreaterThan(twoHits, 0)
        XCTAssertLessThan(twoHits, baseline, "fewer source hits must cost fewer tokens")

        let ledgerOnly = LexicalBaseline.tokens(for: "UniqueLedgerTokenXYZ", repoRoot: dir.path)
        XCTAssertEqual(ledgerOnly, 0, "the .cckit ledger must be excluded from its own baseline")
    }

    func testUnmeasuredSentinelIsNegativeOne() throws {
        try XCTSkipUnless(rgAvailable, "ripgrep required")
        // Empty pattern cannot be probed — must be unmeasured, not 0.
        XCTAssertEqual(LexicalBaseline.tokens(for: "", repoRoot: dir.path), LexicalBaseline.unmeasured)
    }

    func testMeasuredZeroIsDistinctFromUnmeasured() throws {
        try XCTSkipUnless(rgAvailable, "ripgrep required")
        try "unrelated content\n".write(
            to: dir.appendingPathComponent("Source.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LexicalBaseline.tokens(for: "AbsentSymbolQQQ", repoRoot: dir.path), 0)
    }
}
