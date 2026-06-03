import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitRetrieval

/// Orchestrates the assembly of surgical context packets for AI consumption.
///
/// `ContextPacker` intelligently combines various sources of information into a single Markdown document:
/// 1. **Architectural Map**: A budget-aware overview of the repository.
/// 2. **Failure Analysis**: Extracts key error messages from provided log files.
/// 3. **Dependency Crawling**: Automatically identifies and includes related code based on semantic search tasks.
/// 4. **Surgical Precision**: Includes full bodies for primary targets and structural skeletons for supporting context.
///
/// Verified by: `WebContextTests.testWebContextPacking`
public final class ContextPacker {
    private let db: Database
    private let wax: WaxStore
    private let rootPath: String
    private let repoMapBuilder: RepoMapBuilder
    
    public init(db: Database, wax: WaxStore, rootPath: String = ".") {
        self.db = db
        self.wax = wax
        self.rootPath = rootPath
        self.repoMapBuilder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
    }
    
    public func pack(task: String, budget: Int, failureLog: String? = nil) async throws -> String {
        var output = "# Context Packet\n\n"
        output += "## Task\n\(task)\n\n"
        
        // 1. Repo Map (Budget 15%)
        let mapBudget = budget / 7
        let repoMap = try await repoMapBuilder.buildMap(budget: mapBudget, focusTerms: task)
        output += "## Repository Map\n\(repoMap)\n\n"
        
        // 2. Failure Summary
        if let failureLog = failureLog {
            let summary = extractFailureSummary(from: failureLog)
            output += "## Failure Summary\n\(summary)\n\n"
        }
        
        // 3. Intelligent Expansion (Dependency Crawl)
        let searchResults = try await wax.search(task, limit: 10)
        var stagedFiles: Set<String> = []
        var associatedFiles: [String: String] = [:] // Path -> Reason
        
        for res in searchResults {
            if let sym = try db.getSymbols(qualifiedName: res.symbol).first {
                stagedFiles.insert(sym.filePath)
                
                // Dependency Crawl for this symbol's file
                let refs = try db.getReferencesInFile(path: sym.filePath)
                for ref in refs {
                    let defs = try db.getSymbols(qualifiedName: ref.name)
                    for def in defs {
                        if def.filePath != sym.filePath {
                            associatedFiles[def.filePath] = "Defines '\(def.name)' used in '\(sym.filePath.split(separator: "/").last!)'"
                        }
                    }
                }
            }
        }
        
        // 4. Surgical Assembly
        output += "## Surgical Context\n\n"
        
        let rootURL = URL(fileURLWithPath: rootPath)
        var currentTokens = await wax.countTokens(output)
        
        // Full Bodies for Staged Files
        for path in stagedFiles {
            if currentTokens > budget { break }
            let fullURL = rootURL.appendingPathComponent(path)
            if let content = try? String(contentsOf: fullURL, encoding: .utf8) {
                let fileName = (path as NSString).lastPathComponent
                let fence = LanguageFence.fence(for: path)
                let section = "### \(fileName) (FULL)\n```\(fence)\n\(content)\n```\n\n"
                let sectionTokens = await wax.countTokens(section)
                if currentTokens + sectionTokens < budget {
                    output += section
                    currentTokens += sectionTokens
                }
            }
        }
        
        // Skeletons for Associated Files
        for (path, reason) in associatedFiles where !stagedFiles.contains(path) {
            if currentTokens > budget { break }
            let symbols = try db.getSymbols(path: path)
            let skeleton = OutlineRendererRegistry().renderer(for: path).render(filePath: path, symbols: symbols)
            let fileName = (path as NSString).lastPathComponent
            let fileBase = (fileName as NSString).deletingPathExtension
            
            var section = ""
            if symbols.count == 1, let sym = symbols.first, sym.name.lowercased() == fileBase.lowercased() {
                // SINGLE SYMBOL OPTIMIZATION: Header IS the symbol signature
                // Include doc comments in the body if they exist in skeleton
                section = "### \(sym.signature) (SKELETON - \(reason))\n\(skeleton.replacingOccurrences(of: sym.signature, with: "").trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            } else {
                section = "### \(fileName) (SKELETON - \(reason))\n\(skeleton)\n\n"
            }
            
            let sectionTokens = await wax.countTokens(section)
            if currentTokens + sectionTokens < budget {
                output += section
                currentTokens += sectionTokens
            }
        }
        
        let finalTokens = await wax.countTokens(output)
        return "# Context Packet (Tokens: \(finalTokens)/\(budget))\n\n" + String(output.dropFirst(18))
    }
    
    private func extractFailureSummary(from logPath: String) -> String {
        do {
            let content = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let errorLines = lines.filter { $0.lowercased().contains("error:") || $0.lowercased().contains("failed") }
            if errorLines.isEmpty {
                return "No explicit errors found in log."
            }
            return errorLines.prefix(10).joined(separator: "\n")
        } catch {
            return "Could not read failure log: \(error.localizedDescription)"
        }
    }
}
