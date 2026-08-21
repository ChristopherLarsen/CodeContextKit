import XCTest
import Foundation
@testable import CodeContextKitStorage
@testable import CodeContextKitCore

final class StorageTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var tempDbPath: String!
    
    override func setUp() {
        super.setUp()
        tempDbPath = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        db = try! CodeContextKitStorage.Database(path: tempDbPath)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDbPath)
        super.tearDown()
    }
    
    func testContextPacks() throws {
        let items = [
            ["path": "File.swift", "kind": "file", "reason": "Base class"],
            ["path": "Func::File.swift", "kind": "symbol", "reason": "Target logic"]
        ]
        
        try db.saveContextPack(name: "Feature-A", description: "Test Pack", items: items)
        
        let packs = try db.getContextPacks()
        XCTAssertEqual(packs.count, 1)
        XCTAssertEqual(packs[0].name, "Feature-A")
        
        let packItems = try db.getContextPackItems(packId: packs[0].id!)
        XCTAssertEqual(packItems.count, 2)
        XCTAssertEqual(packItems[0].reason, "Base class")
        XCTAssertEqual(packItems[1].reason, "Target logic")
    }
    
    func testWaxFrameBindingsSurviveUntilFileDelete() throws {
        let fileId = try db.saveFile(
            path: "A.swift",
            language: "swift",
            sha256: "abc",
            sizeBytes: 1,
            modifiedAt: Date()
        )
        try db.saveWaxFrames(fileId: fileId, mandate: "mandateA", frameIDs: [3, 4])
        XCTAssertEqual(try db.waxFrameCount(), 2)
        XCTAssertEqual(try db.waxFrameIDs(path: "A.swift").sorted(), [3, 4])
        XCTAssertEqual(try db.allWaxFrameIDs().sorted(), [3, 4])
        XCTAssertEqual(try db.waxMandates(path: "A.swift"), ["mandateA"])

        try db.deleteFile(path: "A.swift")
        XCTAssertEqual(try db.waxFrameCount(), 0)
        XCTAssertEqual(try db.waxFrameIDs(path: "A.swift"), [])
        XCTAssertEqual(try db.allWaxFrameIDs(), [])
    }

    func testFavoritesWithViewMode() throws {
        try db.addFavorite(name: "MyFunc", filePath: "Source.swift", kind: "function", viewMode: "full")
        let favs = try db.getFavorites()
        XCTAssertEqual(favs.count, 1)
        XCTAssertEqual(favs[0].viewMode, "full")
    }

    func testGetSymbolsLikeTreatsPercentAndUnderscoreAsLiterals() throws {
        let fileId = try db.saveFile(
            path: "Wild.swift",
            language: "swift",
            sha256: "x",
            sizeBytes: 1,
            modifiedAt: Date()
        )
        try db.saveSymbols(
            [
                SymbolRecord(
                    kind: .function,
                    name: "foo%bar",
                    qualifiedName: "Wild.foo%bar",
                    signature: "func foo%bar()",
                    filePath: "Wild.swift",
                    startLine: 1,
                    endLine: 1
                ),
                SymbolRecord(
                    kind: .function,
                    name: "fooXbar",
                    qualifiedName: "Wild.fooXbar",
                    signature: "func fooXbar()",
                    filePath: "Wild.swift",
                    startLine: 2,
                    endLine: 2
                ),
                SymbolRecord(
                    kind: .function,
                    name: "foo_bar",
                    qualifiedName: "Wild.foo_bar",
                    signature: "func foo_bar()",
                    filePath: "Wild.swift",
                    startLine: 3,
                    endLine: 3
                ),
            ],
            references: [],
            fileId: fileId
        )

        let percent = try db.getSymbolsLike(name: "foo%bar", strict: true)
        XCTAssertEqual(percent.map(\.name).sorted(), ["foo%bar"])

        let underscore = try db.getSymbolsLike(name: "foo_bar", strict: true)
        XCTAssertEqual(underscore.map(\.name).sorted(), ["foo_bar"])
    }
}
