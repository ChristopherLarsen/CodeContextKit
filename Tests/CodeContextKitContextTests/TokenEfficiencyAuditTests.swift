import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore

/// Contract tests for the 7 September 2026 token-efficiency audit (bugs 1–8, inspection).
final class TokenEfficiencyAuditTests: XCTestCase {
    private var db: Database!
    private var indexer: Indexer!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cckit-audit-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try Database(path: root.appendingPathComponent("index.sqlite").path)
        indexer = Indexer(db: db, wax: nil)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func packer() -> ContextPacker {
        ContextPacker(db: db, wax: nil, rootPath: root.path)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func largeServiceSource(paddingLines: Int = 400) -> String {
        let pads = (1...paddingLines).map { "    let pad\($0) = \($0)" }.joined(separator: "\n")
        return """
        public enum BigAuditService {
            public static func targetMethod() -> String {
                return "TARGET_BODY_MARKER"
            }
        \(pads)
        }
        """
    }

    func testAutoPrefersCompleteCoverageOverEmptyRaw() async throws {
        try write("Big.swift", largeServiceSource())
        try await indexer.index(at: root.path)
        let result = try await packer().pack(task: "targetMethod", budget: 2000, mode: .auto, mapBudget: 0)
        XCTAssertTrue(
            result.deliveredTargetIDs.contains(where: { $0.contains("targetMethod") }),
            "auto must not pick a cheaper empty/raw packet. delivered=\(result.deliveredTargetIDs) mode=\(result.deliveredMode) packet=\(result.packet.prefix(400))"
        )
        XCTAssertTrue(result.packet.contains("TARGET_BODY_MARKER"), result.packet)
        XCTAssertGreaterThan(result.primaryCount, 0)
    }

    func testAutoKeepsPartialPrimariesFromLargeAndSmallFiles() async throws {
        try write("Big.swift", largeServiceSource())
        try write("Small.swift", """
        public enum TinyAuditService {
            public static func secondTarget() -> String { return "SECOND_BODY_MARKER" }
        }
        """)
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "targetMethod secondTarget",
            budget: 2000,
            mode: .auto,
            mapBudget: 0
        )
        XCTAssertTrue(
            result.deliveredTargetIDs.contains(where: { $0.contains("targetMethod") }),
            "auto dropped the large-file primary: \(result.deliveredTargetIDs)"
        )
        XCTAssertTrue(
            result.deliveredTargetIDs.contains(where: { $0.contains("secondTarget") }),
            "auto dropped the small-file primary: \(result.deliveredTargetIDs)"
        )
        XCTAssertTrue(result.packet.contains("TARGET_BODY_MARKER"))
        XCTAssertTrue(result.packet.contains("SECOND_BODY_MARKER"))
    }

    func testQualifiedNameRetrievesTheNamedMethod() async throws {
        try write("Big.swift", largeServiceSource())
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "BigAuditService.targetMethod",
            budget: 2000,
            mode: .surgical,
            mapBudget: 0
        )
        XCTAssertTrue(
            result.deliveredTargetIDs.contains(where: { $0.contains("targetMethod") }),
            "qualified name must not resolve only the enclosing type. delivered=\(result.deliveredTargetIDs) packet=\(result.packet.prefix(500))"
        )
        XCTAssertTrue(result.packet.contains("TARGET_BODY_MARKER"))
    }

    func testTwoExplicitLeavesAreBothDelivered() async throws {
        try write("Big.swift", largeServiceSource(paddingLines: 120))
        try write("Small.swift", """
        public enum TinyAuditService {
            public static func secondTarget() -> String { return "SECOND_BODY_MARKER" }
        }
        """)
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "targetMethod secondTarget",
            budget: 4000,
            mode: .surgical,
            mapBudget: 0
        )
        XCTAssertTrue(result.packet.contains("TARGET_BODY_MARKER"))
        XCTAssertTrue(result.packet.contains("SECOND_BODY_MARKER"))
        XCTAssertGreaterThanOrEqual(result.deliveredTargetIDs.count, 2)
    }

    func testOverloadsAndTypeExtensionArePreserved() async throws {
        try write("Overload.swift", """
        public struct OverloadService {
            public func processValue(_ value: Int) { print(value) }
            public func processValue(_ value: String) { print(value) }
        }
        extension OverloadService {
            public func extraHelper() { print("EXT_MARKER") }
        }
        """)
        try await indexer.index(at: root.path)
        let resolved = try SymbolBodyResolver.resolve(requested: "OverloadService.processValue", db: db)
        guard case .bodies(let symbols, _) = resolved else {
            return XCTFail("expected both overloads, got \(resolved)")
        }
        XCTAssertGreaterThanOrEqual(symbols.count, 2, "overloads must not collapse to one qualified name")
        let signatures = Set(symbols.map(\.signature))
        XCTAssertTrue(signatures.contains(where: { $0.contains("Int") }), "\(signatures)")
        XCTAssertTrue(signatures.contains(where: { $0.contains("String") }), "\(signatures)")

        let typeHit = try SymbolBodyResolver.resolve(requested: "OverloadService", db: db)
        guard case .bodies(let typeSymbols, _) = typeHit else {
            return XCTFail("expected type, got \(typeHit)")
        }
        let extras = try SymbolBodyResolver.extensions(of: typeSymbols[0], db: db)
        XCTAssertTrue(
            extras.contains(where: { $0.kind == .extension }),
            "type fetch must retain the extension declaration"
        )

        let packed = try await packer().pack(task: "OverloadService", budget: 4000, mode: .surgical, mapBudget: 0)
        XCTAssertTrue(packed.packet.contains("EXT_MARKER") || packed.packet.contains("extraHelper"), packed.packet)
    }

    func testSliceRematchesAfterInsertedLines() throws {
        let original = """
        public struct ShiftService {
            public func targetMethod() -> String {
                return "TARGET_BODY_MARKER"
            }
        }
        """
        let shifted = String(repeating: "// inserted padding comment\n", count: 15) + original
        let splitter = SplitterRouter().splitter(for: "Shift.swift")
        let (symbols, _) = splitter.extractSymbols(content: original, filePath: "Shift.swift")
        guard let method = symbols.first(where: { $0.name == "targetMethod" }) else {
            return XCTFail("expected targetMethod in original parse: \(symbols.map(\.name))")
        }
        let hasher = FileHasher()
        let slice = FreshSymbolResolver.slice(
            symbol: method,
            content: shifted,
            indexedHash: hasher.hash(content: original),
            currentHash: hasher.hash(content: shifted)
        )
        XCTAssertTrue(slice.rematched)
        XCTAssertTrue(slice.body.contains("TARGET_BODY_MARKER"), slice.body)
        XCTAssertFalse(slice.body.contains("inserted padding comment"), slice.body)
    }

    func testPreviewOmitsBodiesAndCountsEachHitOnce() async throws {
        try write("Big.swift", largeServiceSource(paddingLines: 120))
        try await indexer.index(at: root.path)
        let result = try await packer().pack(task: "targetMethod", budget: 2000, mode: .preview, mapBudget: 0)
        XCTAssertEqual(result.deliveredMode, .preview)
        XCTAssertTrue(result.packet.contains("Bodies omitted"))
        XCTAssertFalse(result.packet.contains("TARGET_BODY_MARKER"), result.packet)
        XCTAssertFalse(result.packet.contains("(SYMBOL"), result.packet)
        let bannerHits = result.packet.components(separatedBy: "primary: ")
        XCTAssertGreaterThan(bannerHits.count, 1)
        let countPart = bannerHits[1].prefix { $0.isNumber }
        XCTAssertEqual(Int(countPart), result.primaryCount)
        XCTAssertEqual(result.primaryCount, result.deliveredTargetIDs.count)
    }

    func testTokenEstimatorCountsNonLatinLetters() {
        let han = String(repeating: "你", count: 2400)
        XCTAssertGreaterThanOrEqual(TokenEstimator.shared.estimate(han), 2400)
    }

    func testFailureSummaryAndPacketStayNearBudget() async throws {
        try write("Big.swift", largeServiceSource(paddingLines: 80))
        let log = root.appendingPathComponent("build.log")
        let line = "error: " + String(repeating: "x", count: 400)
        try Array(repeating: line, count: 10).joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "targetMethod",
            budget: 512,
            failureLog: log.path,
            mode: .surgical,
            mapBudget: 0
        )
        XCTAssertLessThanOrEqual(result.deliveredTokens, 512)
        XCTAssertTrue(result.packet.contains("Failure Summary") || result.packet.contains("failure summary"))
    }

    func testRawKeepsFilePathAndFailureSummary() async throws {
        try write("Small.swift", """
        public enum TinyAuditService {
            public static func secondTarget() -> String { return "SECOND_BODY_MARKER" }
        }
        """)
        let log = root.appendingPathComponent("build.log")
        try "error: boom failed\n".write(to: log, atomically: true, encoding: .utf8)
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "secondTarget",
            budget: 2000,
            failureLog: log.path,
            mode: .raw,
            mapBudget: 0
        )
        XCTAssertTrue(result.packet.contains("(FULL ·"), result.packet)
        XCTAssertTrue(result.packet.contains("Small.swift"), result.packet)
        XCTAssertTrue(result.packet.contains("Failure Summary"), result.packet)
        XCTAssertTrue(result.packet.contains("boom failed") || result.packet.contains("error:"), result.packet)
    }

    func testEmptyChangedPathsYieldEmptyMapNotWholeRepo() async throws {
        try write("Big.swift", largeServiceSource(paddingLines: 20))
        try await indexer.index(at: root.path)
        let builder = RepoMapBuilder(db: db, counter: { text in TokenEstimator.shared.estimate(text) })
        let empty = try await builder.buildMap(budget: 1000, changedPaths: [])
        XCTAssertTrue(empty.contains("Repository Map"))
        XCTAssertFalse(empty.contains("BigAuditService"), "empty --changed must not dump the whole map:\n\(empty)")
        let full = try await builder.buildMap(budget: 1000)
        XCTAssertTrue(full.contains("BigAuditService") || full.contains("targetMethod") || !full.isEmpty)
    }

    func testNestedGitignoreNegationIsHonored() throws {
        try write(".gitignore", "Generated/\n")
        try write("Generated/.gitignore", "*\n!keep.swift\n")
        try write("Generated/skip.swift", "public enum SkipMe {}\n")
        try write("Generated/keep.swift", "public enum KeepMe {}\n")
        try write("Visible.swift", "public enum Visible {}\n")
        let urls = FileScanner().scan(at: root.path, include: [], exclude: [])
        let names = Set(urls.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("Visible.swift"))
        XCTAssertTrue(names.contains("keep.swift"), "negation should re-include keep.swift; got \(names)")
        XCTAssertFalse(names.contains("skip.swift"), "nested * should exclude skip.swift; got \(names)")
    }

    func testRegexLanguagesAreLocatorOnly() throws {
        XCTAssertFalse(ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: "a.js"))
        XCTAssertFalse(ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: "a.ts"))
        XCTAssertFalse(ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: "A.java"))
        XCTAssertTrue(ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: "A.swift"))
        let splitter = RegexSplitter(language: "js")
        let (symbols, _) = splitter.extractSymbols(
            content: "function greet() {\n  return 1\n}\n",
            filePath: "a.js"
        )
        XCTAssertTrue(symbols.contains(where: { $0.name == "greet" && $0.startLine == $0.endLine }))
    }

    func testOmittedTargetsAreRecorded() async throws {
        try await indexer.index(at: root.path)
        let result = try await packer().pack(
            task: "DefinitelyMissingSymbolXYZ",
            budget: 2000,
            mode: .surgical,
            mapBudget: 0
        )
        XCTAssertTrue(result.omitted.contains(where: { $0.targetID.contains("DefinitelyMissingSymbolXYZ") }))
        XCTAssertTrue(result.requiredTargetIDs.isEmpty)
    }
}
