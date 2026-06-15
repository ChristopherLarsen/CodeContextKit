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
        let hasFocus = (focusTerms != nil && !focusTerms!.isEmpty)
        let symbols = try db.getSymbolsForRepoMap(hasFocus: hasFocus)
        let dbDuration = Date().timeIntervalSince(dbStart)
        if verbose {
            print("[VERBOSE] DB: Fetched \(symbols.count) symbols in \(String(format: "%.3f", dbDuration))s", to: &stderrStream)
        }
        
        let rememberStart = Date()
        
        // 1. Deduplicate symbols by content to prevent identical concurrent inserts (which causes idAlreadyExists)
        var uniqueItems: [(content: String, matchesFocus: Bool)] = []
        var seenContents = Set<String>()
        
        for (index, symbol) in symbols.enumerated() {
            if index % 100 == 0 {
                delegate?.repoMapDidProgress(completed: index, total: symbols.count, currentFile: symbol.filePath)
            }
            
            let fileName = (symbol.filePath as NSString).lastPathComponent
            let fileBase = (fileName as NSString).deletingPathExtension

            let importantKinds: Set<SymbolRecord.Kind> = [.class, .struct, .protocol, .actor, .enum, .interface, .case]
            let isLikelyPublic = symbol.accessLevel == "public" || symbol.accessLevel == "open" || symbol.accessLevel == nil
            let isTestFile = fileBase.lowercased().contains("test")
            
            let matchesFocus = focusTerms?.lowercased().split(separator: " ").contains { term in
                symbol.name.lowercased().contains(term) || (symbol.docComment?.lowercased().contains(term) ?? false)
            } ?? false

            if !matchesFocus {
                // If it's a test file and doesn't match the focus, skip it completely.
                // Test files usually aren't needed for high-level architectural overviews.
                if isTestFile { continue }
                
                if focusTerms != nil {
                    if !importantKinds.contains(symbol.kind) { continue }
                } else {
                    if !importantKinds.contains(symbol.kind) && !isLikelyPublic && !symbol.name.hasPrefix("test") {
                        continue
                    }
                }
            }

            var content = ""
            if symbol.name.lowercased() == fileBase.lowercased() {
                content = "\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
            } else {
                content = "\(fileName): \(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
            }
            
            if let doc = symbol.docComment, !doc.isEmpty {
                content = "/// \(doc.replacingOccurrences(of: "\n", with: "\n/// "))\n\(content)"
            }
            
            if !seenContents.contains(content) {
                seenContents.insert(content)
                uniqueItems.append((content: content, matchesFocus: matchesFocus))
            } else if matchesFocus {
                // If it was already seen but now it matches focus, upgrade its status
                if let idx = uniqueItems.firstIndex(where: { $0.content == content }) {
                    uniqueItems[idx].matchesFocus = true
                }
            }
        }
        
        // 2. Bound concurrency to prevent thread starvation and CoreML bottlenecking
        let rememberCount = try await withThrowingTaskGroup(of: Int.self) { group in
            var count = 0
            let maxConcurrency = 20
            var taskIndex = 0
            
            while taskIndex < min(maxConcurrency, uniqueItems.count) {
                let item = uniqueItems[taskIndex]
                group.addTask {
                    if item.matchesFocus {
                        try await agentContext.remember("FOCUS: " + item.content)
                        try await agentContext.remember(item.content)
                        return 2
                    } else {
                        try await agentContext.remember(item.content)
                        return 1
                    }
                }
                taskIndex += 1
            }
            
            for try await taskCount in group {
                count += taskCount
                if taskIndex < uniqueItems.count {
                    let item = uniqueItems[taskIndex]
                    group.addTask {
                        if item.matchesFocus {
                            try await agentContext.remember("FOCUS: " + item.content)
                            try await agentContext.remember(item.content)
                            return 2
                        } else {
                            try await agentContext.remember(item.content)
                            return 1
                        }
                    }
                    taskIndex += 1
                }
            }
            return count
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
