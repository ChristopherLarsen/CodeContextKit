import XCTest
import CodeContextKitCore
import CodeContextKitRetrieval
import CodeContextKitStorage
@testable import CodeContextKitContext

final class SymbolRankingTests: XCTestCase {
    private func sym(
        name: String,
        qn: String,
        kind: SymbolRecord.Kind,
        path: String,
        start: Int,
        end: Int
    ) -> SymbolRecord {
        SymbolRecord(
            kind: kind,
            name: name,
            qualifiedName: qn,
            signature: name,
            filePath: path,
            startLine: start,
            endLine: end
        )
    }

    func testExactTypeBeforeExactMemberBeforeSubstring() {
        let query = "Settings"
        let exactType = sym(name: "Settings", qn: "Settings", kind: .struct, path: "A.swift", start: 1, end: 10)
        let exactMember = sym(name: "Settings", qn: "Foo.Settings", kind: .property, path: "B.swift", start: 2, end: 2)
        let substring = sym(
            name: "getShouldShowSettingsInMenu",
            qn: "Bar.getShouldShowSettingsInMenu",
            kind: .function,
            path: "C.swift",
            start: 3,
            end: 5
        )
        let ranked = SymbolRanking.ranked([substring, exactMember, exactType], query: query)
        XCTAssertEqual(ranked.map(\.qualifiedName), [
            "Settings",
            "Foo.Settings",
            "Bar.getShouldShowSettingsInMenu",
        ])
    }

    func testGroupedBlockMergesExtensionsAndGroupsByFile() {
        let hits = [
            SymbolRanking.MergedHit(
                qualifiedName: "ProfileHeaderView",
                filePath: "App/ProfileHeaderView.swift",
                kinds: ["struct", "extension"],
                ranges: [(11, 103), (105, 115)],
                bestRank: 0
            ),
            SymbolRanking.MergedHit(
                qualifiedName: "ProfileHeaderView.ViewModel",
                filePath: "App/ProfileHeaderView.swift",
                kinds: ["class"],
                ranges: [(120, 200)],
                bestRank: 1
            ),
            SymbolRanking.MergedHit(
                qualifiedName: "Deeplink.settings",
                filePath: "Core/Deeplink.swift",
                kinds: ["enumEntry"],
                ranges: [(27, 27)],
                bestRank: 2
            ),
        ]
        let block = SymbolRanking.formatGroupedBlock(
            hits: hits,
            query: "Profile",
            totalMerged: 5,
            truncated: true
        )
        let expected = """
        App/ProfileHeaderView.swift
          struct+extension ProfileHeaderView 11-103,105-115
          class ProfileHeaderView.ViewModel 120-200
        Core/Deeplink.swift
          enumEntry Deeplink.settings 27-27
        (+2 more — raise limit or use strict=true)
        """
        XCTAssertEqual(block, expected)
    }

    func testSizeRegressionFortyHitsSixFiles() {
        var symbols: [SymbolRecord] = []
        for fileIdx in 0..<6 {
            for hitIdx in 0..<7 {
                symbols.append(sym(
                    name: "Type\(fileIdx)_\(hitIdx)",
                    qn: "Mod.Type\(fileIdx)_\(hitIdx)",
                    kind: .struct,
                    path: "File\(fileIdx).swift",
                    start: hitIdx + 1,
                    end: hitIdx + 2
                ))
            }
        }
        let (hits, total, truncated) = SymbolRanking.rankMergeLimit(symbols, query: "Type", limit: 40)
        XCTAssertEqual(hits.count, 40)
        XCTAssertTrue(truncated)
        XCTAssertEqual(total, 42)
        let block = SymbolRanking.formatGroupedBlock(
            hits: hits,
            query: "Type",
            totalMerged: total,
            truncated: truncated
        )
        XCTAssertLessThan(block.count, 3000)
    }

    func testExactTypeHitStaysTinyAtDefaultLimit() {
        var symbols = [
            sym(name: "Theme", qn: "Theme", kind: .enum, path: "Theme.swift", start: 1, end: 40),
            sym(name: "fromTheme", qn: "Theme.fromTheme", kind: .function, path: "Theme.swift", start: 42, end: 50),
        ]
        for i in 1...30 {
            symbols.append(sym(
                name: "theme",
                qn: "View\(i).theme",
                kind: .property,
                path: "View\(i).swift",
                start: 2,
                end: 2
            ))
        }
        let (hits, total, truncated) = SymbolRanking.rankMergeLimit(
            symbols,
            query: "Theme",
            limit: SymbolSpanLimits.defaultFindLimit
        )
        XCTAssertEqual(total, 32)
        XCTAssertTrue(truncated)
        XCTAssertTrue(hits.contains { $0.qualifiedName == "Theme" && $0.filePath == "Theme.swift" })
        XCTAssertTrue(hits.contains { $0.filePath == "Theme.swift" })
        XCTAssertFalse(hits.contains { $0.filePath.hasPrefix("View") })
        XCTAssertLessThanOrEqual(hits.count, 1 + SymbolSpanLimits.exactTypeSameFileMemberCap)
    }

    func testRaisedLimitSweepsExactTypeNeighbors() {
        var symbols = [
            sym(name: "Theme", qn: "Theme", kind: .enum, path: "Theme.swift", start: 1, end: 40),
        ]
        for i in 1...25 {
            symbols.append(sym(
                name: "theme",
                qn: "View\(i).theme",
                kind: .property,
                path: "View\(i).swift",
                start: 2,
                end: 2
            ))
        }
        let (hits, _, truncated) = SymbolRanking.rankMergeLimit(
            symbols,
            query: "Theme",
            limit: 40
        )
        XCTAssertFalse(truncated)
        XCTAssertEqual(hits.count, 26)
        XCTAssertTrue(hits.contains { $0.filePath.hasPrefix("View") })
    }
}

final class ReferenceResultFormattingTests: XCTestCase {
    func testGroupingAndContextDedup() {
        let hits = [
            ReferenceResultFormatting.Hit(filePath: "A.swift", startLine: 10, context: "foo"),
            ReferenceResultFormatting.Hit(filePath: "A.swift", startLine: 12, context: "foo"),
            ReferenceResultFormatting.Hit(filePath: "A.swift", startLine: 20, context: "bar"),
            ReferenceResultFormatting.Hit(filePath: "B.swift", startLine: 1, context: nil),
            ReferenceResultFormatting.Hit(filePath: "B.swift", startLine: 2, context: nil),
        ]
        let block = ReferenceResultFormatting.formatBlock(
            leaf: "fetchProfile",
            hits: hits,
            totalCount: 5,
            truncated: false
        )
        XCTAssertTrue(block.contains("refs to 'fetchProfile' — 5 total, showing 5"))
        XCTAssertTrue(block.contains("A.swift: 10(foo), 12, 20(bar)"))
        XCTAssertTrue(block.contains("B.swift: 1, 2"))
    }

    func testLineCapDoesNotDropFile() {
        var hits: [ReferenceResultFormatting.Hit] = []
        for i in 1...30 {
            hits.append(.init(filePath: "Busy.swift", startLine: i, context: nil))
        }
        hits.append(.init(filePath: "Other.swift", startLine: 1, context: nil))
        let block = ReferenceResultFormatting.formatBlock(
            leaf: "x",
            hits: hits,
            totalCount: 31,
            truncated: false
        )
        XCTAssertTrue(block.contains("+5 more"))
        XCTAssertTrue(block.contains("Other.swift: 1"))
    }
}

final class IndexFreshnessCompactTests: XCTestCase {
    func testCompactEmptyWhenFresh() {
        let f = IndexFreshness(
            stale: false,
            indexedCommit: "aaaaaaaaaaaaaaaa",
            indexedBranch: "main",
            headCommit: "aaaaaaaaaaaaaaaa",
            headBranch: "main"
        )
        XCTAssertTrue(f.compactDictionary.isEmpty)
    }

    func testCompactMinimalWhenStale() {
        let f = IndexFreshness(
            stale: true,
            indexedCommit: "1234567890abcdef",
            indexedBranch: "main",
            headCommit: "fedcba0987654321",
            headBranch: "feature"
        )
        let d = f.compactDictionary
        XCTAssertEqual(d["stale"] as? Bool, true)
        XCTAssertEqual(d["indexedCommit"] as? String, "12345678")
        XCTAssertEqual(d["headCommit"] as? String, "fedcba09")
        XCTAssertEqual(d["indexedBranch"] as? String, "main")
        XCTAssertEqual(d["headBranch"] as? String, "feature")
    }

    func testCompactOmitsBranchesWhenSame() {
        let f = IndexFreshness(
            stale: true,
            indexedCommit: "1234567890abcdef",
            indexedBranch: "main",
            headCommit: "fedcba0987654321",
            headBranch: "main"
        )
        let d = f.compactDictionary
        XCTAssertNil(d["indexedBranch"])
        XCTAssertNil(d["headBranch"])
    }
}

final class QueryVariantTests: XCTestCase {
    func testSnakeCaseProducesJoinedAndSpacedVariants() {
        XCTAssertEqual(
            SymbolRanking.queryVariants(for: "refresh_token"),
            ["refreshtoken", "refresh token"]
        )
    }

    func testKebabCaseProducesJoinedAndSpacedVariants() {
        XCTAssertEqual(
            SymbolRanking.queryVariants(for: "refresh-token"),
            ["refreshtoken", "refresh token"]
        )
    }

    func testCamelCaseSplitsIntoWords() {
        XCTAssertEqual(SymbolRanking.queryVariants(for: "RefreshToken"), ["Refresh Token"])
    }

    func testAcronymRunStaysWholeBeforeWord() {
        XCTAssertEqual(SymbolRanking.queryVariants(for: "APIHandler"), ["API Handler"])
    }

    func testSingleWordHasNoVariants() {
        XCTAssertEqual(SymbolRanking.queryVariants(for: "foo"), [])
        XCTAssertEqual(SymbolRanking.queryVariants(for: ""), [])
    }

    func testSplitCamelWordsMixedShapes() {
        XCTAssertEqual(
            SymbolRanking.splitCamelWords("AuthSessionAPI2Handler"),
            ["Auth", "Session", "API", "2", "Handler"]
        )
        XCTAssertEqual(
            SymbolRanking.splitCamelWords("snake_case_name"),
            ["snake", "case", "name"]
        )
    }
}

final class SymbolBodyResolverTests: XCTestCase {
    private var db: Database!

    override func setUp() async throws {
        try await super.setUp()
        db = try Database(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
    }

    private func seed(_ symbols: [SymbolRecord], path: String) throws {
        let fileId = try db.saveFile(
            path: path,
            language: "swift",
            sha256: path,
            sizeBytes: 10,
            modifiedAt: Date()
        )
        try db.saveSymbols(symbols, references: [], fileId: fileId)
    }

    func testBatchResolveTwoNames() throws {
        try seed([
            SymbolRecord(
                kind: .struct,
                name: "Deeplink",
                qualifiedName: "Deeplink",
                signature: "struct Deeplink",
                filePath: "A.swift",
                startLine: 1,
                endLine: 10
            ),
        ], path: "A.swift")
        try seed([
            SymbolRecord(
                kind: .class,
                name: "SettingsViewModel",
                qualifiedName: "SettingsViewModel",
                signature: "class SettingsViewModel",
                filePath: "B.swift",
                startLine: 1,
                endLine: 20
            ),
        ], path: "B.swift")

        var bodies: [String] = []
        for name in ["Deeplink", "SettingsViewModel"] {
            let outcome = try SymbolBodyResolver.resolve(requested: name, db: db)
            guard case .bodies(let syms, _) = outcome else {
                return XCTFail("expected body for \(name)")
            }
            bodies.append(contentsOf: syms.map(\.qualifiedName))
        }
        XCTAssertEqual(Set(bodies), Set(["Deeplink", "SettingsViewModel"]))
        XCTAssertEqual(bodies.count, 2)
    }

    func testLeafFallbackUniqueAndAmbiguous() throws {
        try seed([
            SymbolRecord(
                kind: .function,
                name: "refresh",
                qualifiedName: "AuthSession.refresh",
                signature: "func refresh()",
                filePath: "Auth.swift",
                startLine: 10,
                endLine: 20
            ),
        ], path: "Auth.swift")

        let unique = try SymbolBodyResolver.resolve(requested: "refresh", db: db)
        guard case .bodies(let syms, let from) = unique else {
            return XCTFail("expected unique leaf body")
        }
        XCTAssertEqual(syms.first?.qualifiedName, "AuthSession.refresh")
        XCTAssertEqual(from, "refresh")

        try seed([
            SymbolRecord(
                kind: .function,
                name: "refresh",
                qualifiedName: "Profile.refresh",
                signature: "func refresh()",
                filePath: "Profile.swift",
                startLine: 5,
                endLine: 8
            ),
        ], path: "Profile.swift")

        let ambiguous = try SymbolBodyResolver.resolve(requested: "refresh", db: db)
        guard case .candidates(let block) = ambiguous else {
            return XCTFail("expected candidates for ambiguous leaf, got \(ambiguous)")
        }
        XCTAssertTrue(block.contains("AuthSession.refresh"))
        XCTAssertTrue(block.contains("Profile.refresh"))
    }

    func testMoreThanEightLeafHitsAreTruncatedCandidates() throws {
        for i in 1...9 {
            try seed([
                SymbolRecord(
                    kind: .function,
                    name: "refresh",
                    qualifiedName: "Type\(i).refresh",
                    signature: "func refresh()",
                    filePath: "F\(i).swift",
                    startLine: 1,
                    endLine: 3
                ),
            ], path: "F\(i).swift")
        }
        let outcome = try SymbolBodyResolver.resolve(requested: "refresh", db: db)
        guard case .candidates(let block) = outcome else {
            return XCTFail("expected truncated candidates, got \(outcome)")
        }
        XCTAssertTrue(block.contains("Type"), block)
        XCTAssertTrue(block.contains("more") || block.contains("Type8") || block.contains("Type1"), block)
    }

    func testSlimPayloadOmitsLegacyKeys() throws {
        let sym = SymbolRecord(
            kind: .struct,
            name: "Foo",
            qualifiedName: "Foo",
            signature: "struct Foo",
            filePath: "Foo.swift",
            startLine: 1,
            endLine: 5,
            docComment: "Docs",
            estimatedTokens: 42
        )
        let row = SymbolBodyResolver.slimPayload(
            symbol: sym,
            body: "struct Foo {}",
            resolvedFrom: nil
        )
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("signature"))
        XCTAssertFalse(text.contains("estimatedTokens"))
        XCTAssertFalse(text.contains("bodyTokensEst"))
        XCTAssertFalse(text.contains("accessLevel"))
        XCTAssertTrue(text.contains("qualifiedName"))
        XCTAssertTrue(text.contains("body"))
        // docComment not already in body → included
        XCTAssertTrue(text.contains("docComment"))
    }

    func testHugeTypeReturnsOmissionAndMembers() throws {
        var members: [SymbolRecord] = [
            SymbolRecord(
                kind: .enum,
                name: "PaneInsertionPoint",
                qualifiedName: "PaneInsertionPoint",
                signature: "enum PaneInsertionPoint",
                filePath: "Caret.swift",
                startLine: 1,
                endLine: 260
            ),
        ]
        members.append(
            SymbolRecord(
                kind: .property,
                name: "activeColor",
                qualifiedName: "PaneInsertionPoint.activeColor",
                signature: "var activeColor: NSColor",
                filePath: "Caret.swift",
                startLine: 10,
                endLine: 12,
                enclosingType: "PaneInsertionPoint"
            )
        )
        try seed(members, path: "Caret.swift")

        let huge = try XCTUnwrap(members.first)
        let omission = try SymbolBodyResolver.hugeOmission(for: huge, db: db)
        XCTAssertNotNil(omission)
        XCTAssertTrue(omission?.reason.contains("260") == true, omission?.reason ?? "")
        XCTAssertTrue(omission?.members.contains("activeColor") == true, omission?.members ?? "")

        let small = try XCTUnwrap(members.last)
        XCTAssertNil(try SymbolBodyResolver.hugeOmission(for: small, db: db))
    }
}
