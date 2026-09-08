import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore

final class WebContextTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var fixtureURL: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        let tempDbPath = NSTemporaryDirectory() + uuid + ".sqlite"
        db = try CodeContextKitStorage.Database(path: tempDbPath)
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)
        
        // Use the absolute path to our project fixture
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        fixtureURL = currentDir.appendingPathComponent("Tests/Fixtures/WebProject")
    }
    
    func testWebProjectIndexing() async throws {
        // Index the web fixture
        try await indexer.index(at: fixtureURL.path)
        
        // Verify CSS styles were indexed
        let cssSymbols = try db.getSymbols(path: "css/style.css")
        let styleNames = cssSymbols.map { $0.name }
        
        XCTAssertTrue(styleNames.contains("body"), "Should index element selector 'body'")
        XCTAssertTrue(styleNames.contains(".main-container"), "Should index class selector '.main-container'")
        XCTAssertTrue(styleNames.contains("#header-title"), "Should index ID selector '#header-title'")
        XCTAssertTrue(styleNames.contains(".btn-primary"), "Should index class selector '.btn-primary'")
        XCTAssertTrue(styleNames.contains(":root"), "Should index :root")
        XCTAssertTrue(styleNames.contains("--link-color"), "Should index CSS custom properties")
        XCTAssertTrue(styleNames.contains("--heading-color"), "Should index CSS custom properties")

        let root = cssSymbols.first { $0.name == ":root" }
        XCTAssertEqual(root?.kind, .style)
        XCTAssertGreaterThan(root?.endLine ?? 0, root?.startLine ?? 0)
        XCTAssertEqual(cssSymbols.first { $0.name == "--link-color" }?.kind, .property)
        
        // Verify JS symbols were indexed
        let jsSymbols = try db.getSymbols(path: "js/app.js")
        let jsNames = jsSymbols.map { $0.name }
        
        XCTAssertTrue(jsNames.contains("calculateTotal"), "Should index function 'calculateTotal'")
        XCTAssertTrue(jsNames.contains("formatCurrency"), "Should index arrow function 'formatCurrency'")
        XCTAssertTrue(jsNames.contains("ShoppingCart"), "Should index class 'ShoppingCart'")
        XCTAssertTrue(jsNames.contains("fetchData"), "Should index async function 'fetchData'")
        
        // Verify kinds
        XCTAssertEqual(cssSymbols.first(where: { $0.name == "body" })?.kind, .style)
        XCTAssertEqual(jsSymbols.first(where: { $0.name == "calculateTotal" })?.kind, .function)
        XCTAssertEqual(jsSymbols.first(where: { $0.name == "ShoppingCart" })?.kind, .class)
    }
    
    func testWebContextPacking() async throws {
        try await indexer.index(at: fixtureURL.path)
        
        let packer = ContextPacker(db: db, wax: wax, rootPath: fixtureURL.path)
        
        // Ask for an exact declaration so the assertion does not depend on
        // nondeterministic semantic ranking between calculateTotal and ShoppingCart.
        let result = try await packer.pack(
            task: "calculateTotal",
            budget: 4000,
            mode: .surgical
        )
        let packet = result.packet
        
        // Regex-indexed JS records declaration locators, not reliable closing spans.
        // Surgical mode must identify that limitation instead of claiming a
        // one-line declaration is the function body; callers can request full mode.
        XCTAssertTrue(packet.contains("### calculateTotal (LOCATOR"), packet)
        XCTAssertTrue(packet.contains("function calculateTotal(items) {"), packet)
        XCTAssertTrue(packet.contains("Implementation span is unavailable"), packet)
        XCTAssertFalse(packet.contains("return items.reduce"), packet)
        XCTAssertEqual(result.requiredTargetIDs, result.deliveredTargetIDs)
        XCTAssertTrue(
            result.omitted.contains(where: { $0.reason.contains("locator-only language") }),
            "Expected an explicit locator-only capability notice: \(result.omitted)"
        )
        XCTAssertTrue(packet.contains("mode: surgical"), "Packet should include surgical token banner")
    }

    func testWebContextPackingFullMode() async throws {
        try await indexer.index(at: fixtureURL.path)

        let packer = ContextPacker(db: db, wax: wax, rootPath: fixtureURL.path)
        let packet = try await packer.pack(
            task: "calculate total in shopping cart",
            budget: 4000,
            mode: .full
        ).packet
        XCTAssertTrue(packet.contains("mode: full"))
        XCTAssertTrue(packet.contains("function calculateTotal"), "Full pack should still contain JS function body")
    }
}
