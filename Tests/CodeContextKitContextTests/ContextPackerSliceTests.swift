import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore

final class ContextPackerSliceTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var packer: ContextPacker!
    var fixtureURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        db = try CodeContextKitStorage.Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)

        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        fixtureURL = currentDir.appendingPathComponent("Tests/Fixtures/PackSliceProject")
        packer = ContextPacker(db: db, wax: wax, rootPath: fixtureURL.path)
    }

    func testFormatSymbolSectionIncludesLineRange() {
        let symbol = SymbolRecord(
            kind: .function,
            name: "targetFunction",
            qualifiedName: "PackSliceTarget.targetFunction",
            signature: "public static func targetFunction(input: String) -> String",
            filePath: "Sources/PackSlice.swift",
            startLine: 6,
            endLine: 9,
            estimatedTokens: 20
        )
        let section = packer.formatSymbolSection(
            symbol: symbol,
            body: "public static func targetFunction(input: String) -> String {\n    return \"target:\" + input\n}"
        )
        XCTAssertTrue(section.contains("(SYMBOL · Sources/PackSlice.swift:6-9)"))
        XCTAssertTrue(section.contains("```swift"))
        XCTAssertTrue(section.contains("targetFunction"))
        XCTAssertFalse(section.contains("(FULL"))
    }

    func testSameFileRelatedHintsSurfaceNeighbors() {
        let target = SymbolRecord(
            kind: .method,
            name: "run",
            qualifiedName: "Worker.run",
            signature: "func run()",
            filePath: "Worker.swift",
            startLine: 10,
            endLine: 20,
            enclosingType: "Worker"
        )
        let helper = SymbolRecord(
            kind: .method,
            name: "helper",
            qualifiedName: "Worker.helper",
            signature: "private func helper()",
            filePath: "Worker.swift",
            startLine: 22,
            endLine: 25,
            enclosingType: "Worker"
        )
        let caller = SymbolRecord(
            kind: .method,
            name: "start",
            qualifiedName: "Worker.start",
            signature: "func start()",
            filePath: "Worker.swift",
            startLine: 1,
            endLine: 8,
            enclosingType: "Worker"
        )
        let refs = [
            SymbolRecord.Reference(name: "helper", startLine: 12, endLine: 12, context: "run"),
            SymbolRecord.Reference(name: "run", startLine: 4, endLine: 4, context: "start"),
        ]
        let hints = packer.buildSameFileRelatedHints(
            symbol: target,
            fileSymbols: [caller, target, helper],
            fileRefs: refs
        )
        XCTAssertTrue(hints.text.contains("Same-file callees:"), hints.text)
        XCTAssertTrue(hints.text.contains("helper"), hints.text)
        XCTAssertTrue(hints.text.contains("Same-file callers:"), hints.text)
        XCTAssertTrue(hints.text.contains("start"), hints.text)
        XCTAssertTrue(hints.text.contains("Sibling members"), hints.text)
        XCTAssertFalse(hints.text.contains("full=true"), hints.text)
        XCTAssertFalse(hints.text.contains("Other symbols in file"), hints.text)
        let guidance = packer.packingGuidanceSection(relatedHintCap: 5, anyTruncated: false)
        XCTAssertTrue(guidance.contains("gather_code_context"), guidance)
        XCTAssertTrue(guidance.contains("mode=full"), guidance)
        XCTAssertFalse(guidance.contains("full=true"), guidance)
    }

    func testSameFileRelatedHintsNoteWhenCapped() {
        let target = SymbolRecord(
            kind: .function,
            name: "main",
            qualifiedName: "main",
            signature: "func main()",
            filePath: "Big.swift",
            startLine: 1,
            endLine: 5
        )
        var fileSymbols = [target]
        var refs: [SymbolRecord.Reference] = []
        for i in 1...10 {
            let name = "helper\(i)"
            fileSymbols.append(
                SymbolRecord(
                    kind: .function,
                    name: name,
                    qualifiedName: name,
                    signature: "func \(name)()",
                    filePath: "Big.swift",
                    startLine: 10 + i,
                    endLine: 12 + i
                )
            )
            refs.append(SymbolRecord.Reference(name: name, startLine: 2, endLine: 2, context: "main"))
        }
        let hints = packer.buildSameFileRelatedHints(
            symbol: target,
            fileSymbols: fileSymbols,
            fileRefs: refs,
            limitPerCategory: 5
        )
        XCTAssertTrue(hints.truncated)
        XCTAssertTrue(hints.text.contains("+5 more not listed"), hints.text)
        let guidance = packer.packingGuidanceSection(relatedHintCap: 5, anyTruncated: true)
        XCTAssertTrue(guidance.contains("capped at 5"), guidance)
        XCTAssertTrue(guidance.contains("Neighbor bodies are omitted"), guidance)
    }

    func testPackingGuidanceMentionsFullEscalation() {
        let guidance = packer.packingGuidanceSection(relatedHintCap: 5, anyTruncated: false)
        XCTAssertTrue(guidance.contains("gather_code_context"), guidance)
        XCTAssertTrue(guidance.contains("mode=full"), guidance)
        XCTAssertTrue(guidance.contains("surgical"), guidance)
        XCTAssertFalse(guidance.contains("full=true"), guidance)
    }

    func testShouldPreferFullFileForTinyAndFileKind() {
        // At/under 100 lines → whole file, no surgical chrome.
        let tiny = (1...ContextPacker.tinyFileLineThreshold).map { _ in "let x = 1" }.joined(separator: "\n")
        XCTAssertEqual(tiny.components(separatedBy: .newlines).count, ContextPacker.tinyFileLineThreshold)
        let tinySymbol = SymbolRecord(
            kind: .function,
            name: "f",
            qualifiedName: "f",
            signature: "func f()",
            filePath: "Tiny.swift",
            startLine: 1,
            endLine: 3
        )
        XCTAssertTrue(packer.shouldPreferFullFile(symbol: tinySymbol, content: tiny, body: "func f() {}"))
        XCTAssertEqual(ContextPacker.tinyFileLineThreshold, 100)

        // Just over the line threshold with a small body → surgical slice, not full dump.
        let justOver = (1...(ContextPacker.tinyFileLineThreshold + 1)).map { _ in "let x = 1" }.joined(separator: "\n")
        XCTAssertFalse(
            packer.shouldPreferFullFile(symbol: tinySymbol, content: justOver, body: "func f() {}")
        )

        let fileKind = SymbolRecord(
            kind: .file,
            name: "Big.swift",
            qualifiedName: "Big.swift",
            signature: "File: Big.swift",
            filePath: "Big.swift",
            startLine: 1,
            endLine: 200
        )
        let big = String(repeating: "let x = 1\n", count: 200)
        XCTAssertTrue(packer.shouldPreferFullFile(symbol: fileKind, content: big, body: big))

        let sliceSymbol = SymbolRecord(
            kind: .function,
            name: "small",
            qualifiedName: "small",
            signature: "func small()",
            filePath: "Big.swift",
            startLine: 1,
            endLine: 3
        )
        XCTAssertFalse(
            packer.shouldPreferFullFile(
                symbol: sliceSymbol,
                content: big,
                body: "func small() {\n}\n"
            )
        )
    }

    func testTinyFileEmitsFullWithoutRelatedChrome() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-tiny-\(UUID().uuidString)", isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("TinyTarget.swift")
        let source = """
        public enum TinyTarget {
            public static func run() -> String {
                return "tiny-ok"
            }
        }
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertLessThanOrEqual(
            source.components(separatedBy: .newlines).count,
            ContextPacker.tinyFileLineThreshold
        )

        let localIndexer = Indexer(db: db, wax: wax)
        try await localIndexer.index(at: dir.path)
        let localPacker = ContextPacker(db: db, wax: wax, rootPath: dir.path)

        let packet = try await localPacker.pack(
            task: "TinyTarget run",
            budget: 8000,
            mode: .surgical,
            mapBudget: 0
        ).packet
        let hits = try await wax.search("TinyTarget run", limit: 5)
        if hits.isEmpty {
            throw XCTSkip("Wax search returned no hits for tiny fixture")
        }
        XCTAssertTrue(packet.contains("(FULL"), "Tiny file should dump whole content:\n\(packet.prefix(800))")
        XCTAssertFalse(packet.contains("Same-file related:"), "No surgical related chrome on tiny files")
        XCTAssertFalse(packet.contains("## Packing notes"), "No escalate notes when only full dumps")
        XCTAssertTrue(packet.contains("tiny-ok"))
        try? FileManager.default.removeItem(at: dir)
    }

    func testCompetitiveEmitPrefersFullWhenChromeExceedsFile() {
        let symbol = SymbolRecord(
            kind: .function,
            name: "main",
            qualifiedName: "main",
            signature: "func main()",
            filePath: "Modest.swift",
            startLine: 1,
            endLine: 3
        )
        // Body is tiny; invent heavy related chrome.
        var fileSymbols = [symbol]
        var refs: [SymbolRecord.Reference] = []
        for i in 1...10 {
            let name = "helper\(i)"
            fileSymbols.append(
                SymbolRecord(
                    kind: .function,
                    name: name,
                    qualifiedName: name,
                    signature: "func \(name)()",
                    filePath: "Modest.swift",
                    startLine: 10 + i,
                    endLine: 12 + i
                )
            )
            refs.append(SymbolRecord.Reference(name: name, startLine: 2, endLine: 2, context: "main"))
        }
        let hints = packer.buildSameFileRelatedHints(
            symbol: symbol,
            fileSymbols: fileSymbols,
            fileRefs: refs
        )
        let body = "func main() {\n    helper1()\n}"
        // File only slightly larger than the body — chrome tips the scale.
        let content = body + "\n" + (1...10).map { "func helper\($0)() {}\n" }.joined()
        let symbolSection = packer.formatSymbolSection(symbol: symbol, body: body, relatedHints: hints.text)
        let fullSection = packer.formatFullFileSection(path: "Modest.swift", content: content)
        XCTAssertGreaterThan(
            symbolSection.count,
            fullSection.count,
            "Related chrome should make the surgical section larger than the whole modest file"
        )
    }

    func testSurgicalPackEmitsSymbolSliceNotNoise() async throws {
        try await indexer.index(at: fixtureURL.path)

        let symbols = try db.getSymbols(path: "Sources/PackSlice.swift")
        XCTAssertTrue(
            symbols.contains(where: { $0.name == "targetFunction" }),
            "Fixture should index targetFunction"
        )
        XCTAssertTrue(
            symbols.contains(where: { $0.name == "unrelatedNoiseFunction" }),
            "Fixture should index unrelatedNoiseFunction"
        )

        let packet = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 4000,
            mode: .surgical
        ).packet

        XCTAssertTrue(
            packet.contains("mode: surgical"),
            "Banner should report surgical mode. Packet:\n\(packet.prefix(500))"
        )
        XCTAssertTrue(
            packet.contains("targetFunction") || packet.contains("PackSliceTarget"),
            "Packet should include the target symbol. Packet:\n\(packet.prefix(1500))"
        )

        let hits = try await wax.search("targetFunction PackSliceTarget", limit: 10)
        if hits.isEmpty {
            throw XCTSkip("Wax search returned no hits; cannot assert slice vs full-file behavior")
        }
        XCTAssertTrue(
            packet.contains("(SYMBOL"),
            "Expected surgical symbol slice when Wax returns hits. Packet:\n\(packet.prefix(1500))"
        )
        XCTAssertFalse(
            packet.contains("UNIQUE_MARKER_NOISE_XYZ_DO_NOT_PACK"),
            "Surgical pack should not include the unrelated noise marker"
        )
        XCTAssertTrue(
            packet.contains("Sources/PackSlice.swift:"),
            "Symbol header should include path and line range"
        )
    }

    func testFullModeIncludesNoiseMarker() async throws {
        try await indexer.index(at: fixtureURL.path)

        let packet = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 8000,
            mode: .full
        ).packet

        XCTAssertTrue(packet.contains("mode: full"))
        let hits = try await wax.search("targetFunction PackSliceTarget", limit: 10)
        if hits.isEmpty {
            throw XCTSkip("Wax search returned no hits; cannot assert full-file dump behavior")
        }
        XCTAssertTrue(
            packet.contains("(FULL"),
            "Full mode should dump primary files when Wax returns hits"
        )
        XCTAssertTrue(
            packet.contains("UNIQUE_MARKER_NOISE_XYZ_DO_NOT_PACK"),
            "Full mode should include the entire primary file"
        )
    }

    func testBudgetIsRespected() async throws {
        try await indexer.index(at: fixtureURL.path)
        let budget = 800
        let packet = try await packer.pack(
            task: "targetFunction PackSliceTarget unrelatedNoiseFunction",
            budget: budget,
            mode: .surgical
        ).packet
        if let match = packet.firstMatch(of: /Tokens: (\d+)\/(\d+)/),
           let used = Int(match.1),
           let limit = Int(match.2) {
            XCTAssertEqual(limit, budget)
            XCTAssertLessThanOrEqual(used, budget + 50, "Packet should stay near budget")
        } else {
            XCTFail("Missing token banner in packet")
        }
    }

    func testSurgicalSavesTokensVersusFullOnFixture() async throws {
        try await indexer.index(at: fixtureURL.path)

        let surgical = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 8000,
            mode: .surgical,
            mapBudget: 400
        ).packet
        let full = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 8000,
            mode: .full,
            mapBudget: 400
        ).packet

        let surgicalTokens = await wax.countTokens(surgical)
        let fullTokens = await wax.countTokens(full)
        XCTAssertLessThan(
            surgicalTokens,
            fullTokens,
            "Surgical pack should use fewer tokens than full for a small symbol in a large file"
        )
        let savings = Double(fullTokens - surgicalTokens) / Double(fullTokens)
        XCTAssertGreaterThan(
            savings,
            0.15,
            "Expected >15% savings on PackSlice fixture; got \(Int(savings * 100))% (surgical=\(surgicalTokens), full=\(fullTokens))"
        )
        XCTAssertTrue(surgical.contains("mode: surgical"))
        XCTAssertTrue(full.contains("mode: full"))

        if let match = surgical.firstMatch(of: /Tokens: (\d+)\/(\d+)/),
           let bannerTokens = Int(match.1) {
            XCTAssertEqual(
                bannerTokens,
                surgicalTokens,
                "Banner token count should match the assembled packet"
            )
        } else {
            XCTFail("Missing token banner in surgical packet")
        }
    }

    func testNeighborBodiesGuidanceAppearsOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-multi-\(UUID().uuidString)", isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        // Three oversized files so surgical prefers slices (not tiny-file full dumps).
        func writeLarge(_ name: String, typeName: String, fn: String) throws {
            var lines = ["public enum \(typeName) {", "    public static func \(fn)() -> String {", "        return \"\(fn)\"" , "    }"]
            for i in 1...110 {
                lines.append("    public static let pad\(i) = \(i)")
            }
            lines.append("}")
            try lines.joined(separator: "\n")
                .write(to: sources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try writeLarge("A.swift", typeName: "TypeA", fn: "alphaFn")
        try writeLarge("B.swift", typeName: "TypeB", fn: "betaFn")
        try writeLarge("C.swift", typeName: "TypeC", fn: "gammaFn")

        try await indexer.index(at: dir.path)
        let localPacker = ContextPacker(db: db, wax: wax, rootPath: dir.path)
        let packet = try await localPacker.pack(
            task: "alphaFn betaFn gammaFn",
            budget: 12000,
            mode: .surgical,
            mapBudget: 0
        ).packet

        let symbolSections = packet.components(separatedBy: "(SYMBOL").count - 1
        XCTAssertGreaterThanOrEqual(symbolSections, 3, "Expected ≥3 symbol sections. Packet:\n\(packet.prefix(2000))")
        let phrase = "Neighbor bodies are omitted"
        let occurrences = packet.components(separatedBy: phrase).count - 1
        XCTAssertEqual(occurrences, 1, "Guidance footer must appear once per packet, not per section")

        try? FileManager.default.removeItem(at: dir)
    }

    func testPackingNotesOmittedWhenRelatedListsFit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-notes-\(UUID().uuidString)", isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var lines = ["public enum Fit {", "    public static func alphaFn() -> String { \"a\" }"]
        for i in 1...3 {
            lines.append("    public static func helper\(i)() -> Int { \(i) }")
        }
        lines.append("}")
        for i in 1...110 {
            lines.append("// pad \(i)")
        }
        try lines.joined(separator: "\n")
            .write(to: sources.appendingPathComponent("Fit.swift"), atomically: true, encoding: .utf8)

        try await indexer.index(at: dir.path)
        let localPacker = ContextPacker(db: db, wax: wax, rootPath: dir.path)
        let packet = try await localPacker.pack(
            task: "alphaFn",
            budget: 12000,
            mode: .surgical,
            mapBudget: 0
        ).packet
        XCTAssertTrue(packet.contains("alphaFn"), packet.prefix(800).description)
        XCTAssertFalse(
            packet.contains("## Packing notes"),
            "Untruncated related lists should not spend budget on packing notes. Packet:\n\(packet.suffix(800))"
        )
        try? FileManager.default.removeItem(at: dir)
    }

    func testAutoSkipsFullWhenSurgicalBeatsRaw() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-auto-\(UUID().uuidString)", isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var lines = ["public enum Big {", "    public static func alphaFn() -> String { \"a\" }"]
        for i in 1...120 {
            lines.append("    public static let pad\(i) = \(i)")
        }
        lines.append("}")
        try lines.joined(separator: "\n")
            .write(to: sources.appendingPathComponent("Big.swift"), atomically: true, encoding: .utf8)

        try await indexer.index(at: dir.path)
        let localPacker = ContextPacker(db: db, wax: wax, rootPath: dir.path)
        let result = try await localPacker.pack(
            task: "alphaFn",
            budget: 3000,
            mode: .auto
        )
        XCTAssertEqual(result.deliveredMode, .surgical, "slice should beat whole-file raw")
        XCTAssertNil(
            result.fullBaselineTokens,
            "auto must skip the full assembly when surgical already ≤ raw"
        )
        XCTAssertEqual(result.surgicalTokens, result.deliveredTokens)
        try? FileManager.default.removeItem(at: dir)
    }

    func testAutoBudget3000NeverExceedsWholeFileBaseline() async throws {
        try await indexer.index(at: fixtureURL.path)
        let result = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 3000,
            mode: .auto
        )
        XCTAssertGreaterThan(result.sourceWholeFileTokens, 0)
        XCTAssertLessThanOrEqual(
            result.deliveredTokens,
            result.sourceWholeFileTokens,
            "auto should stay at or under the primary-file baseline aside from packet chrome (delivered=\(result.deliveredTokens), source=\(result.sourceWholeFileTokens), mode=\(result.deliveredMode))"
        )
    }

    func testSmallBudgetOmitsRepositoryMap() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 3000,
            mode: .surgical
        ).packet
        XCTAssertFalse(
            packet.contains("## Repository Map"),
            "budget < 6000 should omit the map header entirely"
        )
    }

    func testIdentifierTaskSkipsVectorFill() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "targetFunction",
            budget: 12000,
            mode: .surgical,
            mapBudget: 0
        ).packet
        XCTAssertTrue(packet.contains("targetFunction"))
        XCTAssertFalse(
            packet.contains("UNIQUE_MARKER_NOISE_XYZ_DO_NOT_PACK"),
            "Named-identifier pack must not vector-fill leftover slots. Packet:\n\(packet.prefix(1500))"
        )
    }

    func testIdentifierMissDoesNotVectorFill() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "DefinitelyMissingSymbolXYZ",
            budget: 12000,
            mode: .surgical,
            mapBudget: 0
        ).packet
        XCTAssertFalse(
            packet.contains("UNIQUE_MARKER_NOISE_XYZ_DO_NOT_PACK"),
            "Identifier miss must not dump vector neighbors. Packet:\n\(packet.prefix(1500))"
        )
        XCTAssertFalse(packet.contains("targetFunction"))
    }

    func testIdentifierTaskOmitsRepoMapAtLargeBudget() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "targetFunction PackSliceTarget",
            budget: 12000,
            mode: .surgical
        ).packet
        XCTAssertFalse(
            packet.contains("## Repository Map"),
            "Named-identifier pack must skip the repo map. Packet:\n\(packet.prefix(800))"
        )
        XCTAssertTrue(packet.contains("targetFunction") || packet.contains("PackSliceTarget"))
    }

    func testTwoNamedHitsInProseKeepRepoMap() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "match the highlight using targetFunction and PackSliceTarget",
            budget: 12000,
            mode: .surgical
        ).packet
        XCTAssertTrue(
            packet.contains("## Repository Map"),
            "Two named hits in prose must keep filler. Packet:\n\(packet.prefix(800))"
        )
    }

    func testSingleNameInProseKeepsRepoMap() async throws {
        try await indexer.index(at: fixtureURL.path)
        let packet = try await packer.pack(
            task: "how does PackSliceTarget handle packing noise",
            budget: 12000,
            mode: .surgical
        ).packet
        XCTAssertTrue(
            packet.contains("## Repository Map"),
            "One CamelCase name in prose should still orient. Packet:\n\(packet.prefix(800))"
        )
    }
}
