import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitSwiftIndex
import ContextCore

public protocol RepoMapProgressDelegate: Sendable {
    func repoMapDidProgress(completed: Int, total: Int, currentFile: String)
}

/// Constructs a high-level architectural overview of the repository within a token budget.
public final class RepoMapBuilder {
    private let db: Database
    private let counter: @Sendable (String) async -> Int
    
    public init(db: Database, counter: @escaping @Sendable (String) async -> Int) {
        self.db = db
        self.counter = counter
    }
    
    public func buildMap(budget: Int, focusTerms: String? = nil, delegate: RepoMapProgressDelegate? = nil, verbose: Bool = false) async throws -> String {
        var stderrStream = StderrOutputStream()
        let totalStartTime = Date()
        let taskDescription = focusTerms ?? "Provide an architectural overview of the repository focusing on core modules and their relationships."
        
        // Use a configuration that allows more chunks to fill the budget
        var config = ContextConfiguration.default
        config.episodicMemoryK = 500 // Allow up to 500 symbols
        config.semanticMemoryK = 500
        
        let agentContext = try AgentContext(configuration: config)
        try await agentContext.beginSession(systemPrompt: "You are an architectural mapping engine. Provide concise, high-signal symbol skeletons.")
        
        let dbStart = Date()
        let allFiles = try db.getAllFiles()
        let dbDuration = Date().timeIntervalSince(dbStart)
        if verbose {
            print("[VERBOSE] DB: Fetched \(allFiles.count) files in \(String(format: "%.3f", dbDuration))s", to: &stderrStream)
        }
        
        let totalFiles = allFiles.count
        var rememberCount = 0
        let rememberStart = Date()
        
        for (index, file) in allFiles.enumerated() {
            delegate?.repoMapDidProgress(completed: index, total: totalFiles, currentFile: file.path)
            let symbols = try db.getSymbols(fileId: file.id!)
            
            let fileName = (file.path as NSString).lastPathComponent
            let fileBase = (fileName as NSString).deletingPathExtension

            for symbol in symbols {
                let importantKinds: Set<SymbolRecord.Kind> = [.class, .struct, .protocol, .actor, .enum, .interface, .case]
                let isLikelyPublic = symbol.accessLevel == "public" || symbol.accessLevel == "open" || symbol.accessLevel == nil
                
                // If focusing, be more selective but ALWAYS include focused matches
                let matchesFocus = focusTerms?.lowercased().split(separator: " ").contains { term in
                    symbol.name.lowercased().contains(term) || (symbol.docComment?.lowercased().contains(term) ?? false)
                } ?? false

                if !matchesFocus {
                    // Aggressively filter out non-important symbols if we have focus terms
                    if focusTerms != nil {
                        if !importantKinds.contains(symbol.kind) { continue }
                    } else {
                        if !importantKinds.contains(symbol.kind) && !isLikelyPublic && !symbol.name.hasPrefix("test") {
                            continue
                        }
                    }
                }

                // Format the symbol as a high-signal memory chunk
                var content = ""
                if symbol.name.lowercased() == fileBase.lowercased() {
                    content = "\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
                } else {
                    content = "\(fileName): \(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
                }
                
                if let doc = symbol.docComment, !doc.isEmpty {
                    content = "/// \(doc.replacingOccurrences(of: "\n", with: "\n/// "))\n\(content)"
                }
                
                let startRem = Date()
                // If it matches focus, "boost" it by remembering it multiple times or adding a tag
                if matchesFocus {
                    try await agentContext.remember("FOCUS: " + content)
                    try await agentContext.remember(content)
                    rememberCount += 2
                } else {
                    try await agentContext.remember(content)
                    rememberCount += 1
                }
                let remDur = Date().timeIntervalSince(startRem)
                if verbose && remDur > 0.05 {
                    print("[VERBOSE] SLOW: remembering symbol '\(symbol.name)' in \(fileName) took \(String(format: "%.3f", remDur))s", to: &stderrStream)
                }
            }
        }
        let rememberDuration = Date().timeIntervalSince(rememberStart)
        if verbose {
            print("[VERBOSE] Context: Remembered \(rememberCount) symbol chunks in \(String(format: "%.3f", rememberDuration))s", to: &stderrStream)
        }
        
        // Pass 2: ContextCore performs Attention Centrality ranking and Progressive Compression
        let buildStart = Date()
        let window = try await agentContext.buildWindow(currentTask: taskDescription, maxTokens: budget)
        let buildDuration = Date().timeIntervalSince(buildStart)
        if verbose {
            print("[VERBOSE] Centrality: Built window (ranking & compression) in \(String(format: "%.3f", buildDuration))s", to: &stderrStream)
        }
        
        let joinStart = Date()
        let mapContent = window.chunks
            .filter { !$0.isSystemPrompt }
            .sorted(by: { $0.score > $1.score }) // Keep important ones at top or keep original order? 
            // Actually, keep original order if possible, but buildWindow reranks.
            .map(\.content)
            .joined(separator: "\n---\n")
        let joinDuration = Date().timeIntervalSince(joinStart)
        if verbose {
            print("[VERBOSE] Format: Joined map content in \(String(format: "%.3f", joinDuration))s", to: &stderrStream)
            let totalDuration = Date().timeIntervalSince(totalStartTime)
            print("[VERBOSE] Total Map Time: \(String(format: "%.3f", totalDuration))s", to: &stderrStream)
        }
        
        var header = "# Repository Map (Tokens: \(window.totalTokens)/\(budget))\n\n"
        header += "SYSTEM: CCKit/ContextCore integrated mapping engine. Centrality ranking applied.\n\n"
        
        return header + mapContent
    }
}

private struct StderrOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        fputs(string, stderr)
        fflush(stderr)
    }
}
