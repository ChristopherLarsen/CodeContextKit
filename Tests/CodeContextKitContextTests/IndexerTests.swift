import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitCore
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval

final class IndexerTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var tempDir: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        let tempDbPath = NSTemporaryDirectory() + uuid + ".sqlite"
        db = try CodeContextKitStorage.Database(path: tempDbPath)
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)
        
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testIncrementalIndexing() async throws {
        let fileURL = tempDir.appendingPathComponent("Test.swift")
        try "struct A {}".write(to: fileURL, atomically: true, encoding: .utf8)
        
        // First run
        let first = try await indexer.index(at: tempDir.path)
        XCTAssertTrue(first.rebuiltWax)
        let files1 = try db.getAllFiles()
        XCTAssertEqual(files1.count, 1)
        
        // Second run (no changes)
        let second = try await indexer.index(at: tempDir.path)
        XCTAssertFalse(second.rebuiltWax)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.skipped, 1)
        let files2 = try db.getAllFiles()
        XCTAssertEqual(files2.count, 1)
        XCTAssertEqual(files2[0].sha256, files1[0].sha256)
        
        // Change file
        try "struct B {}".write(to: fileURL, atomically: true, encoding: .utf8)
        let changed = try await indexer.index(at: tempDir.path)
        XCTAssertTrue(changed.rebuiltWax)
        
        let symbols = try db.getSymbols(path: "Test.swift")
        XCTAssertTrue(symbols.contains { $0.name == "B" })
    }

    func testMultiLanguageIndexing() async throws {
        // Create a JSON file in the root of the test directory
        let jsonURL = tempDir.appendingPathComponent("config.json")
        try "{ \"key\": \"value\" }".write(to: jsonURL, atomically: true, encoding: .utf8)
        
        let first = try await indexer.index(at: tempDir.path)
        XCTAssertTrue(first.rebuiltWax)
        
        let files = try db.getAllFiles()
        XCTAssertTrue(files.contains { $0.path == "config.json" })
        XCTAssertEqual(files.first { $0.path == "config.json" }?.language, "json")
        
        // Non-Swift files should be indexed as a single 'file' symbol for search
        let symbols = try db.getSymbols(path: "config.json")
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, .file)

        // File fallbacks are intentionally excluded from Wax. Their coverage
        // marker must still make the next unchanged run a true no-op.
        let second = try await indexer.index(at: tempDir.path)
        XCTAssertFalse(second.rebuiltWax)
        XCTAssertEqual(second.updated, 0)
        XCTAssertEqual(second.skipped, 1)
    }

    func testIndexingDefaultsToGitignore() async throws {
        let keptURL = tempDir.appendingPathComponent("Sources")
        let ignoredURL = tempDir.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
        try "Generated/\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "struct Kept {}".write(to: keptURL.appendingPathComponent("Kept.swift"), atomically: true, encoding: .utf8)
        try "struct Ignored {}".write(to: ignoredURL.appendingPathComponent("Ignored.swift"), atomically: true, encoding: .utf8)

        try await indexer.index(at: tempDir.path)

        let files = try db.getAllFiles()
        XCTAssertTrue(files.contains { $0.path == "Sources/Kept.swift" })
        XCTAssertFalse(files.contains { $0.path == "Generated/Ignored.swift" })
    }

    func testSavedExcludedFoldersAreRemovedFromExistingIndex() async throws {
        let keptURL = tempDir.appendingPathComponent("Sources")
        let ignoredURL = tempDir.appendingPathComponent("Vendor")
        try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
        try "struct Kept {}".write(to: keptURL.appendingPathComponent("Kept.swift"), atomically: true, encoding: .utf8)
        try "struct Ignored {}".write(to: ignoredURL.appendingPathComponent("Ignored.swift"), atomically: true, encoding: .utf8)

        try await indexer.index(at: tempDir.path)
        XCTAssertEqual(try db.getAllFiles().count, 2)

        try ProjectSettings(excludedFolders: ["Vendor"]).save(projectRoot: tempDir.path)
        try await indexer.index(at: tempDir.path)

        let files = try db.getAllFiles()
        XCTAssertTrue(files.contains { $0.path == "Sources/Kept.swift" })
        XCTAssertFalse(files.contains { $0.path == "Vendor/Ignored.swift" })
    }

    func testIncludedFoldersOverrideGitignore() async throws {
        let ignoredURL = tempDir.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
        try "Generated/\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "struct Included {}".write(to: ignoredURL.appendingPathComponent("Included.swift"), atomically: true, encoding: .utf8)

        try ProjectSettings(includedFolders: ["Generated"]).save(projectRoot: tempDir.path)
        try await indexer.index(at: tempDir.path)

        let files = try db.getAllFiles()
        XCTAssertTrue(files.contains { $0.path == "Generated/Included.swift" })
    }

    func testExcludedFoldersWinOverIncludedFolders() async throws {
        let folderURL = tempDir.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "Generated/\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "struct Blocked {}".write(to: folderURL.appendingPathComponent("Blocked.swift"), atomically: true, encoding: .utf8)

        try ProjectSettings(excludedFolders: ["Generated"], includedFolders: ["Generated"]).save(projectRoot: tempDir.path)
        try await indexer.index(at: tempDir.path)

        let files = try db.getAllFiles()
        XCTAssertFalse(files.contains { $0.path == "Generated/Blocked.swift" })
    }
}
