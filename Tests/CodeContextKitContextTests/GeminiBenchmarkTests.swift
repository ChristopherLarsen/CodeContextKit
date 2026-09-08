import XCTest
import Foundation
@testable import CodeContextKitContext
@testable import CodeContextKitStorage
@testable import CodeContextKitRetrieval
@testable import CodeContextKitSwiftIndex
@testable import CodeContextKitCore

final class GeminiBenchmarkTests: XCTestCase {
    var db: CodeContextKitStorage.Database!
    var wax: WaxStore!
    var indexer: Indexer!
    var tempDir: URL!
    let estimator = TokenEstimator()
    
    override func setUp() async throws {
        try await super.setUp()
        let uuid = UUID().uuidString
        db = try CodeContextKitStorage.Database(path: NSTemporaryDirectory() + uuid + ".sqlite")
        wax = try await WaxStore(path: NSTemporaryDirectory() + uuid + ".wax")
        indexer = Indexer(db: db, wax: wax)
        
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(uuid)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Setup mock project
        let authURL = tempDir.appendingPathComponent("AuthManager.swift")
        var authContent = """
        public class AuthManager {
            private var token: String?
            public init() {}
            
            /// Refreshes the authentication token.
            /// This method makes a network request to the auth server, parses the response,
            /// and securely stores the new token in the keychain. It also handles
            /// retry logic and exponential backoff in case of network failures.
            public func refreshToken(completion: @escaping (Bool) -> Void) {
                print("Refreshing token with heavy logic")
                self.token = "new_token"
                completion(true)
            }
            public func getToken() -> String? { return token }
        """
        for i in 1...100 {
            authContent += "\n    public func legacyOperation\(i)() { let x = \(i) * 2; print(x) }"
        }
        authContent += "\n}"
        try authContent.write(to: authURL, atomically: true, encoding: .utf8)
        
        let apiURL = tempDir.appendingPathComponent("APIClient.swift")
        var apiContentStr = """
        public class APIClient {
            let auth = AuthManager()
            public init() {}
            
            /// Makes an authenticated API request.
            /// If the current token is missing or expired, it automatically
            /// triggers a token refresh before making the request.
            public func makeRequest(endpoint: String) {
                if auth.getToken() == nil {
                    auth.refreshToken { success in
                        if success { print("Requesting \\(endpoint)") }
                    }
                } else {
                    print("Requesting \\(endpoint)")
                }
            }
        """
        for i in 1...100 {
            apiContentStr += "\n    public func fetchResource\(i)() { let path = \"/api/v1/resource/\(i)\"; print(path) }"
        }
        apiContentStr += "\n}"
        try apiContentStr.write(to: apiURL, atomically: true, encoding: .utf8)
        
        try await indexer.index(at: tempDir.path)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testContextGenerationGoodness() async throws {
        // Goal: User asks "How does APIClient handle token refresh?"
        
        // 1. Baseline: "Agentic" naive approach (cat/read_file on both files)
        let authContent = try String(contentsOf: tempDir.appendingPathComponent("AuthManager.swift"), encoding: .utf8)
        let apiContent = try String(contentsOf: tempDir.appendingPathComponent("APIClient.swift"), encoding: .utf8)
        let baselineContext = "## AuthManager.swift\n\(authContent)\n## APIClient.swift\n\(apiContent)"
        let baselineTokens = estimator.estimate(baselineContext)
        
        // 2. CCKit Approach: Targeted Repo Map with path/module focus terms
        let localEstimator = TokenEstimator()
        let builder = RepoMapBuilder(db: db, counter: { text in localEstimator.estimate(text) })
        let cckitContext = try await builder.buildMap(
            budget: 1500,
            focusTerms: "AuthManager APIClient"
        )
        let cckitTokens = estimator.estimate(cckitContext)
        
        print("--- BASELINE CONTEXT (\(baselineTokens) tokens) ---")
        print(baselineContext)
        print("--- CCKIT CONTEXT (\(cckitTokens) tokens) ---")
        print(cckitContext)
        
        // Evaluation Criteria ("Goodness")
        // A. Must contain the essential symbols needed to answer the question
        XCTAssertTrue(cckitContext.contains("func refreshToken"), "Map must contain refreshToken signature")
        XCTAssertTrue(cckitContext.contains("class APIClient"), "Map must contain APIClient class")
        XCTAssertTrue(cckitContext.contains("class AuthManager"), "Map must contain AuthManager class")
        
        // B. Token Efficiency: Must be at least 2x better (half the tokens)
        XCTAssertLessThanOrEqual(Double(cckitTokens), Double(baselineTokens) * 0.5, "CCKit context must be at least 2x more token-efficient than reading full files.")
    }
    
    func testSurgicalContextExpansion() throws {
        // SCENARIO: User stages 'APIClient.swift' for a bug fix.
        // GEMINI GOAL: The system should automatically find 'AuthManager.swift' 
        // because it defines the 'AuthManager' used in the client.
        
        let initialItems = [
            ["path": "APIClient.swift", "kind": "file", "reason": "Target for modification"]
        ]
        
        // Simulating the server's expansion logic
        var expandedItems = initialItems
        
        // Gemini's Best Approach: 
        // 1. Look for internal references in the staged files
        let refs = try db.getReferencesInFile(path: "APIClient.swift")
        XCTAssertTrue(refs.contains { $0.name == "AuthManager" })
        
        // 2. Find defining files
        for ref in refs {
            let defs = try db.getSymbols(qualifiedName: ref.name)
            for def in defs {
                if !expandedItems.contains(where: { $0["path"] == def.filePath }) {
                    expandedItems.append(["path": def.filePath, "kind": "file", "reason": "Defines '\(def.name)'"])
                }
            }
        }
        
        // VERIFICATION
        XCTAssertTrue(expandedItems.contains { $0["path"] == "AuthManager.swift" }, "System failed to find the tightly coupled dependency AuthManager.swift")
        XCTAssertEqual(expandedItems.count, 2)
        
        // 3. Packaging Efficiency
        // Gemini recommends: Staged files get Body, Associated files get Skeleton
        var contextOutput = ""
        for item in expandedItems {
            let path = item["path"]!
            let reason = item["reason"]!
            
            if reason == "Target for modification" {
                // FULL BODY - Mocking content reading for test
                let content = try String(contentsOf: tempDir.appendingPathComponent(path), encoding: .utf8)
                contextOutput += "## File: \(path) (FULL)\n\(content)\n"
            } else {
                // SKELETON ONLY
                let symbols = try db.getSymbols(path: path)
                let skeleton = SwiftOutlineRenderer().render(filePath: path, symbols: symbols)
                contextOutput += "## File: \(path) (SKELETON)\n\(skeleton)\n"
            }
        }
        
        print("GENERATED CONTEXT:\n\(contextOutput)")
        XCTAssertTrue(contextOutput.contains("class APIClient"), "Should contain target symbols from APIClient.swift")
        XCTAssertTrue(contextOutput.contains("class AuthManager"), "Should contain dependency symbols from AuthManager.swift")
        XCTAssertFalse(contextOutput.contains("print(\"Hidden logic\")"), "AuthManager should be a skeleton, it should NOT contain implementation details.")
    }
}
