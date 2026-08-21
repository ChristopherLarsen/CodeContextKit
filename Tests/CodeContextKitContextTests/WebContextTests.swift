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
        
        // Pack context based on a task that relates to our symbols
        let packet = try await packer.pack(task: "calculate total in shopping cart", budget: 4000).packet
        
        // ContextPacker uses Wax search to find relevant symbols, then emits
        // symbol body slices (or FULL for tiny files). calculateTotal should appear.
        XCTAssertTrue(packet.contains("function calculateTotal"), "Packet should contain JS function body")
        XCTAssertTrue(packet.contains("mode: surgical") || packet.contains("Tokens:"), "Packet should include token banner")
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
