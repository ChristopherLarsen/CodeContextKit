import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore

final class IncrementalIndexingTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var packer: ContextPacker!
    var tempDir: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        db = try CodeContextKitStorage.Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)
        
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        packer = ContextPacker(db: db, wax: wax, rootPath: tempDir.path)
    }
    
    override func tearDown() async throws {
        // Close deterministically: Wax enqueues background maintenance on
        // flush(), and deallocating the store without close() leaves that task
        // racing process teardown.
        try? await wax.close()
        wax = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }
    
    func testFileChangeDetection() async throws {
        let fileURL = tempDir.appendingPathComponent("Feature.swift")
        
        // 1. Initial Index
        try "struct Original { }".write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        
        let originalSymbol = try db.getSymbols(path: "Feature.swift").first
        XCTAssertEqual(originalSymbol?.name, "Original")
        
        // 2. Modify File
        try "struct Modified { }".write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        
        let updatedSymbols = try db.getSymbols(path: "Feature.swift")
        XCTAssertEqual(updatedSymbols.count, 1)
        XCTAssertEqual(updatedSymbols.first?.name, "Modified")
        XCTAssertFalse(updatedSymbols.contains { $0.name == "Original" }, "Stale symbol 'Original' was not removed.")
    }
    
    func testContextPacketFreshness() async throws {
        let fileURL = tempDir.appendingPathComponent("Task.swift")
        
        // 1. Index initial version
        try "func runTask() { print(\"Old\") }".write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        
        // 2. Modify on disk
        try "func runTask() { print(\"New Content\") }".write(to: fileURL, atomically: true, encoding: .utf8)
        
        // 3. Generate packet BEFORE re-indexing
        // Packer uses Wax to find relevant files, then reads from disk for bodies.
        let packetBefore = try await packer.pack(task: "runTask", budget: 1000).packet
        XCTAssertTrue(packetBefore.contains("New Content"), "Packer should read latest content from disk even if index is stale.")
        
        // 4. Re-index and verify symbols
        try await indexer.index(at: tempDir.path)
        let packetAfter = try await packer.pack(task: "runTask", budget: 1000).packet
        XCTAssertTrue(packetAfter.contains("New Content"))
    }
    
    func testFileDeletionHandling() async throws {
        let fileURL = tempDir.appendingPathComponent("DeleteMe.swift")
        try "struct Gone { }".write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        
        XCTAssertNotNil(try db.getFile(path: "DeleteMe.swift"))
        
        // Delete file
        try FileManager.default.removeItem(at: fileURL)
        
        // Re-index
        try await indexer.index(at: tempDir.path)
        
        XCTAssertNil(try db.getFile(path: "DeleteMe.swift"), "Deleted file still exists in database.")
    }

    func testReindexDeletesStaleWaxVectors() async throws {
        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")

        let fileURL = tempDir.appendingPathComponent("Needle.swift")
        try """
        public enum AlphaZuluOrphan {
            /// unique phrase alpha-zulu-orphan-vector-leak
            public static func leftover() {}
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)

        XCTAssertGreaterThan(try db.waxFrameCount(), 0, "Wax frame IDs/mandates must be persisted")
        let originalHits = try await wax.search("unique phrase alpha-zulu-orphan-vector-leak", limit: 5)
        XCTAssertTrue(
            originalHits.contains { $0.symbol.contains("AlphaZuluOrphan") || $0.preview.contains("alpha-zulu-orphan") },
            "Expected original needle in Wax. Hits: \(originalHits.map(\.symbol))"
        )

        try """
        public enum BravoYankeeFresh {
            /// unique phrase bravo-yankee-fresh-vector-keep
            public static func current() {}
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)

        let staleHits = try await wax.search("unique phrase alpha-zulu-orphan-vector-leak", limit: 8)
        XCTAssertFalse(
            staleHits.contains { $0.preview.contains("alpha-zulu-orphan") || $0.symbol.contains("AlphaZuluOrphan") },
            "Stale Wax vectors leaked after re-index. Hits: \(staleHits.map { "\($0.symbol): \($0.preview.prefix(80))" })"
        )

        let freshHits = try await wax.search("unique phrase bravo-yankee-fresh-vector-keep", limit: 5)
        XCTAssertTrue(
            freshHits.contains { $0.symbol.contains("BravoYankeeFresh") || $0.preview.contains("bravo-yankee-fresh") },
            "Replacement needle missing. Hits: \(freshHits.map(\.symbol))"
        )
    }

    func testDeletedFileRetractsWaxVectors() async throws {
        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")

        let fileURL = tempDir.appendingPathComponent("Gone.swift")
        try """
        public struct WaxGoneNeedle {
            /// unique phrase wax-gone-needle-retract
            public func vanish() {}
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)
        XCTAssertGreaterThan(try db.waxFrameCount(), 0)

        try FileManager.default.removeItem(at: fileURL)
        try await indexer.index(at: tempDir.path)

        XCTAssertNil(try db.getFile(path: "Gone.swift"))
        XCTAssertEqual(try db.waxFrameCount(), 0)
        let hits = try await wax.search("unique phrase wax-gone-needle-retract", limit: 5)
        XCTAssertFalse(
            hits.contains { $0.preview.contains("wax-gone-needle-retract") || $0.symbol.contains("WaxGoneNeedle") },
            "Deleted file still in Wax. Hits: \(hits.map(\.symbol))"
        )
    }

    func testIndexPersistsMandatesWhenWaxReturnsNoFrameIDs() async throws {
        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")

        let fileURL = tempDir.appendingPathComponent("IDs.swift")
        try """
        public struct SaveReturnedIDs {
            /// unique phrase save-returned-frame-ids
            public func keep() {}
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)

        let ids = try db.waxFrameIDs(path: "IDs.swift")
        let mandates = try db.waxMandates(path: "IDs.swift")
        XCTAssertTrue(ids.isEmpty, "Current Wax Memory.save intentionally returns no frame IDs")
        XCTAssertFalse(mandates.isEmpty, "cckit must retain a semantic-ingest bookkeeping row")
    }

    func testForcedWaxRebuildDropsOrphanVectors() async throws {
        let embeddingsReady = await wax.hasEmbeddings()
        try XCTSkipUnless(embeddingsReady, "MiniLM embeddings required")

        let fileURL = tempDir.appendingPathComponent("Keep.swift")
        try """
        public struct CompactKeepNeedle {
            /// unique phrase compact-keep-vector
            public func stay() {}
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        try await indexer.index(at: tempDir.path)

        let leaked = SymbolRecord(
            kind: .struct,
            name: "CompactOrphanNeedle",
            qualifiedName: "CompactOrphanNeedle",
            signature: "struct CompactOrphanNeedle",
            filePath: "Missing.swift",
            startLine: 1,
            endLine: 4,
            docComment: "unique phrase compact-orphan-vector"
        )
        let ingest = try await wax.saveSymbol(
            leaked,
            body: """
            /// unique phrase compact-orphan-vector
            public struct CompactOrphanNeedle {}
            """
        )
        XCTAssertTrue(ingest.didWrite)
        try await wax.flush()

        let beforeOrphan = try await wax.search("unique phrase compact-orphan-vector", limit: 5)
        XCTAssertTrue(
            beforeOrphan.contains { $0.preview.contains("compact-orphan-vector") || $0.symbol.contains("CompactOrphanNeedle") },
            "Expected planted orphan. Hits: \(beforeOrphan.map(\.symbol))"
        )

        let result = try await indexer.index(at: tempDir.path, forceWaxRebuild: true)
        XCTAssertGreaterThan(result.deleted, 0)
        XCTAssertTrue(result.rebuiltWax)

        let afterOrphan = try await wax.search("unique phrase compact-orphan-vector", limit: 5)
        XCTAssertFalse(
            afterOrphan.contains { $0.preview.contains("compact-orphan-vector") || $0.symbol.contains("CompactOrphanNeedle") },
            "Orphan survived compact. Hits: \(afterOrphan.map(\.symbol))"
        )

        let kept = try await wax.search("unique phrase compact-keep-vector", limit: 5)
        XCTAssertTrue(
            kept.contains { $0.symbol.contains("CompactKeepNeedle") || $0.preview.contains("compact-keep-vector") },
            "Live symbol dropped by compact. Hits: \(kept.map(\.symbol))"
        )
    }
}
