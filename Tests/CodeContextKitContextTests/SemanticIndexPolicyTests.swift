import XCTest
import Foundation
@testable import CodeContextKitRetrieval
@testable import CodeContextKitCore
@testable import CodeContextKitContext
@testable import CodeContextKitStorage

final class SemanticIndexPolicyTests: XCTestCase {
    func testSkipsUndocumentedEmptyMethodStubs() {
        let stub = SymbolRecord(
            kind: .function,
            name: "doThing",
            qualifiedName: "Noise.doThing",
            signature: "public func doThing()",
            filePath: "Noise.swift",
            startLine: 1,
            endLine: 1
        )
        XCTAssertFalse(SemanticIndexPolicy.shouldIndex(stub, body: "public func doThing() {}"))
    }

    func testIndexesTypesEvenWithoutDocs() {
        let type = SymbolRecord(
            kind: .class,
            name: "HTTPClient",
            qualifiedName: "HTTPClient",
            signature: "public class HTTPClient",
            filePath: "Net.swift",
            startLine: 1,
            endLine: 5
        )
        XCTAssertTrue(SemanticIndexPolicy.shouldIndex(type, body: "public class HTTPClient {\n}"))
    }

    func testIndexesDocumentedMethods() {
        let method = SymbolRecord(
            kind: .function,
            name: "refreshToken",
            qualifiedName: "AuthManager.refreshToken",
            signature: "public func refreshToken()",
            filePath: "Auth.swift",
            startLine: 3,
            endLine: 3,
            docComment: "Refreshes the authentication token with retry and exponential backoff."
        )
        XCTAssertTrue(SemanticIndexPolicy.shouldIndex(method, body: "public func refreshToken() {}"))
    }

    func testSkipsFileKind() {
        let file = SymbolRecord(
            kind: .file,
            name: "big.swift",
            qualifiedName: "big.swift",
            signature: "File: big.swift",
            filePath: "big.swift",
            startLine: 1,
            endLine: 500
        )
        XCTAssertFalse(SemanticIndexPolicy.shouldIndex(file, body: String(repeating: "x", count: 2000)))
    }

    func testIdentifierHeavyDetection() {
        // Bare / dotted / snake names → lexical
        XCTAssertTrue(SemanticIndexPolicy.queryLooksIdentifierHeavy("ScaleNeedle renewGalacticCredentials"))
        XCTAssertTrue(SemanticIndexPolicy.queryLooksIdentifierHeavy("AuthManager.refreshToken"))
        XCTAssertTrue(SemanticIndexPolicy.queryLooksIdentifierHeavy("pack_savings_ledger"))
        XCTAssertTrue(SemanticIndexPolicy.queryLooksIdentifierHeavy("SemanticIndexPolicy"))
        XCTAssertTrue(SemanticIndexPolicy.queryLooksIdentifierHeavy("AuthManager"))

        // Pure NL and prose that merely mentions a type → vector
        XCTAssertFalse(SemanticIndexPolicy.queryLooksIdentifierHeavy("how do we renew credentials after expiry"))
        XCTAssertFalse(SemanticIndexPolicy.queryLooksIdentifierHeavy(
            "actor that wraps Wax Memory for semantic symbol retrieval"
        ))
        XCTAssertFalse(SemanticIndexPolicy.queryLooksIdentifierHeavy(
            "how does AuthManager handle token refresh"
        ))
        XCTAssertFalse(SemanticIndexPolicy.queryLooksIdentifierHeavy(
            "where is ContextPacker used"
        ))
        XCTAssertFalse(SemanticIndexPolicy.queryLooksIdentifierHeavy(
            "fix SemanticIndexPolicy for selective indexing"
        ))
    }

    func testSkipPackFillerOnlyWhenIdentifierHeavy() {
        XCTAssertTrue(SemanticIndexPolicy.shouldSkipPackFiller(task: "AuthManager"))
        XCTAssertTrue(SemanticIndexPolicy.shouldSkipPackFiller(task: "AuthManager.refreshToken"))
        XCTAssertFalse(SemanticIndexPolicy.shouldSkipPackFiller(
            task: "match caret using FormatBarView and PaneInsertionPoint"
        ))
        XCTAssertFalse(SemanticIndexPolicy.shouldSkipPackFiller(
            task: "how does AuthManager handle token refresh"
        ))
        XCTAssertFalse(SemanticIndexPolicy.shouldSkipPackFiller(
            task: "how do we renew credentials after expiry"
        ))
    }

    func testIdentifierTokensExtractedFromProse() {
        let tokens = SemanticIndexPolicy.identifierTokens(
            in: "Fix gameStateLabel when renewGalacticCredentials fails"
        )
        XCTAssertTrue(tokens.contains("gameStateLabel"))
        XCTAssertTrue(tokens.contains("renewGalacticCredentials"))
        XCTAssertFalse(tokens.contains("when"))
    }

    func testDocumentTextIncludesDocs() {
        let method = SymbolRecord(
            kind: .function,
            name: "refreshToken",
            qualifiedName: "AuthManager.refreshToken",
            signature: "public func refreshToken()",
            filePath: "Auth.swift",
            startLine: 3,
            endLine: 3,
            docComment: "Refreshes the authentication token."
        )
        let text = SemanticIndexPolicy.documentText(for: method, body: "public func refreshToken() {}")
        XCTAssertTrue(text.contains("Refreshes the authentication token."))
        XCTAssertTrue(text.count >= SemanticIndexPolicy.minimumDocumentLength)
    }

    func testCLISearchRoute() {
        XCTAssertEqual(
            SearchRoute.resolveCLI("AuthManager"),
            .lexical("AuthManager", includeGrep: true, allowVectorFallback: false)
        )
        XCTAssertEqual(
            SearchRoute.resolveCLI("how do we renew credentials after expiry"),
            .lexical("how do we renew credentials after expiry", includeGrep: true, allowVectorFallback: false)
        )
        XCTAssertEqual(
            SearchRoute.resolveCLI("semantic:AuthManager.refreshToken"),
            .lexical("AuthManager.refreshToken", includeGrep: false, allowVectorFallback: false)
        )
        XCTAssertEqual(
            SearchRoute.resolveCLI("semantic:ScaleNeedle renewGalacticCredentials"),
            .lexical("ScaleNeedle renewGalacticCredentials", includeGrep: false, allowVectorFallback: true)
        )
        XCTAssertEqual(
            SearchRoute.resolveCLI("semantic:how do we renew credentials after expiry"),
            .vector("how do we renew credentials after expiry")
        )
    }

    func testVisualizerSearchRoute() {
        XCTAssertEqual(
            SearchRoute.resolveVisualizer("AuthManager.refreshToken"),
            .lexical("AuthManager.refreshToken", includeGrep: false, allowVectorFallback: false)
        )
        XCTAssertEqual(
            SearchRoute.resolveVisualizer("semantic:AuthManager.refreshToken"),
            .lexical("AuthManager.refreshToken", includeGrep: false, allowVectorFallback: false)
        )
        XCTAssertEqual(
            SearchRoute.resolveVisualizer("how do we renew credentials after expiry"),
            .vector("how do we renew credentials after expiry")
        )
        XCTAssertEqual(
            SearchRoute.resolveVisualizer("semantic:how does AuthManager handle token refresh"),
            .vector("how does AuthManager handle token refresh")
        )
    }
}

/// Lexical-only mode precedence: explicit flag > CCKIT_NO_SEMANTIC (either
/// direction) > the persisted `.cckit/lexical-only` marker.
final class LexicalOnlyRequestedTests: XCTestCase {
    private func withCckitDir(_ body: (String) throws -> Void) throws {
        let dir = NSTemporaryDirectory() + "cckit-lexical-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            unsetenv("CCKIT_NO_SEMANTIC")
        }
        try body(dir)
    }

    private func writeMarker(_ cckitDir: String) throws {
        try Data("1\n".utf8).write(
            to: URL(fileURLWithPath: SemanticIndexPolicy.lexicalOnlyMarkerPath(cckitDir: cckitDir)),
            options: .atomic
        )
    }

    func testExplicitFlagWinsOverEverything() throws {
        try withCckitDir { dir in
            setenv("CCKIT_NO_SEMANTIC", "0", 1)
            XCTAssertTrue(SemanticIndexPolicy.lexicalOnlyRequested(flag: true, cckitDir: dir))
        }
    }

    func testEnvTrueOptsInWithoutMarker() throws {
        try withCckitDir { dir in
            setenv("CCKIT_NO_SEMANTIC", "1", 1)
            XCTAssertTrue(SemanticIndexPolicy.lexicalOnlyRequested(flag: false, cckitDir: dir))
        }
    }

    func testMarkerPersistsModeWithoutFlagOrEnv() throws {
        try withCckitDir { dir in
            try writeMarker(dir)
            XCTAssertTrue(SemanticIndexPolicy.lexicalOnlyRequested(flag: false, cckitDir: dir))
        }
    }

    func testNoMarkerNoFlagNoEnvIsSemantic() throws {
        try withCckitDir { dir in
            XCTAssertFalse(SemanticIndexPolicy.lexicalOnlyRequested(flag: false, cckitDir: dir))
        }
    }

    func testExplicitEnvFalseOverridesMarkerForUpgradePath() throws {
        try withCckitDir { dir in
            try writeMarker(dir)
            for value in ["0", "false", "no", "off"] {
                setenv("CCKIT_NO_SEMANTIC", value, 1)
                XCTAssertFalse(
                    SemanticIndexPolicy.lexicalOnlyRequested(flag: false, cckitDir: dir),
                    "CCKIT_NO_SEMANTIC=\(value) must override the marker"
                )
            }
        }
    }

    func testUnrecognizedEnvValueDoesNotOverrideMarker() throws {
        try withCckitDir { dir in
            try writeMarker(dir)
            setenv("CCKIT_NO_SEMANTIC", "maybe", 1)
            XCTAssertTrue(SemanticIndexPolicy.lexicalOnlyRequested(flag: false, cckitDir: dir))
        }
    }
}

/// Verifies natural-language semantic search returns meaning matches, not only BM25 keyword hits.
final class SemanticSearchTests: XCTestCase {
    func testNaturalLanguageQueryFindsAuthRefreshWithoutKeywordOverlap() async throws {
        let uuid = UUID().uuidString
        let db = try CodeContextKitStorage.Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        let wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        let waxReady = await wax.isAvailable()
        XCTAssertTrue(waxReady, "Wax Memory with embedder should open")
        let embeddingsReady = await wax.hasEmbeddings()
        XCTAssertTrue(embeddingsReady, "MiniLM embeddings must be enabled for semantic search")

        let indexer = Indexer(db: db, wax: wax)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authURL = tempDir.appendingPathComponent("AuthManager.swift")
        try """
        public class AuthManager {
            /// Refreshes the authentication token with retry and exponential backoff.
            public func refreshToken() {}
            public func login(username: String, password: String) {}
        }
        """.write(to: authURL, atomically: true, encoding: .utf8)

        let netURL = tempDir.appendingPathComponent("HTTPClient.swift")
        try """
        public class HTTPClient {
            public func get(url: String) {}
        }
        """.write(to: netURL, atomically: true, encoding: .utf8)

        try await indexer.index(at: tempDir.path)

        // No shared tokens with refreshToken / AuthManager — requires vector retrieval.
        let query = "how do we renew credentials after expiry"
        let hits = try await wax.search(query, limit: 5)
        XCTAssertFalse(hits.isEmpty, "Expected semantic hits for NL query; got none (text-only BM25?)")

        let names = hits.map(\.symbol)
        XCTAssertTrue(
            names.contains(where: { $0.contains("refreshToken") || $0.contains("AuthManager") }),
            "Expected AuthManager/refreshToken in hits, got: \(names)"
        )
        // HTTPClient must not monopolize a credentials/auth query.
        let top = names.prefix(3).joined(separator: ", ")
        XCTAssertTrue(
            names.prefix(3).contains(where: { $0.contains("refreshToken") || $0.contains("AuthManager") }),
            "Expected auth symbol in top 3, got: \(top)"
        )
    }

    func testSelectiveIndexingSkipsNoiseStubsSoNeedleSurfaces() async throws {
        let uuid = UUID().uuidString
        let db = try CodeContextKitStorage.Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        let wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        let indexer = Indexer(db: db, wax: wax)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        public enum ScaleNeedle {
            /// Unique passphrase about renewing expired galactic credentials after supernova.
            public static func renewGalacticCredentials() {}
        }
        """.write(to: tempDir.appendingPathComponent("Needle.swift"), atomically: true, encoding: .utf8)

        var noise = ""
        for i in 0..<200 {
            noise += """
            public struct Noise\(i) {
                public func doThing\(i)() {}
            }

            """
        }
        try noise.write(to: tempDir.appendingPathComponent("Noise.swift"), atomically: true, encoding: .utf8)

        try await indexer.index(at: tempDir.path)

        let hits = try await wax.search(
            "renewing expired galactic credentials after supernova",
            limit: 10
        )
        let names = hits.map(\.symbol)
        XCTAssertTrue(
            names.contains(where: { $0.contains("ScaleNeedle") || $0.contains("Galactic") }),
            "Needle should surface when stubs are not indexed. Hits: \(names)"
        )
        XCTAssertTrue(
            names.first?.contains("ScaleNeedle") == true || names.first?.contains("Galactic") == true,
            "Needle should rank first. Hits: \(names)"
        )
    }
}
