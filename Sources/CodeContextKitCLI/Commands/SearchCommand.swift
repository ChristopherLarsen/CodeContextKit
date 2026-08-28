import ArgumentParser
import Foundation
import CodeContextKitRetrieval
import CodeContextKitStorage
import CodeContextKitCore
import CodeContextKitSwiftIndex
import CodeContextKitContext

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Unified search tool for symbols, literal text (grep), and semantic meaning."
    )

    @Argument(help: "The search query. Prefix with 'semantic:' for meaning search.")
    var query: String

    @Flag(name: .shortAndLong, help: "Treat the query as a regular expression.")
    var regex: Bool = false

    @Flag(name: .shortAndLong, help: "Require ALL terms to match (AND logic) for lexical/file/symbol/grep search. Not applicable to vector meaning search.")
    var strict: Bool = false

    @Flag(help: "Force semantic (vector) meaning search even for identifier-like queries.")
    var vector: Bool = false

    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    @Option(help: "Limit the number of results.")
    var limit: Int = 100

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        let waxPath = ".cckit/repo.wax"
        
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }

        let route: SearchRoute = vector
            ? .vector(SearchRoute.strippedQuery(query))
            : SearchRoute.resolveCLI(query)
        let db = try Database(path: dbPath)
        let wax = try await WaxStore(path: waxPath)

        // Read-path integrity gate. Vector reads must never answer from a
        // truncated or unfinished arena — their `0 results` reads as a
        // confident negative. Lexical reads answer from SQLite (still real),
        // so they carry the fault as a warning instead of failing.
        let gate = await WaxReadGate.evaluate(waxPath: waxPath, cckitDir: ".cckit", db: db, wax: wax)
        let isVectorRoute: Bool
        if case .vector = route {
            isVectorRoute = true
        } else {
            isVectorRoute = false
        }
        if isVectorRoute, let fault = gate.hardFault {
            print("Error: \(fault.localizedDescription)")
            throw ExitCode.failure
        }
        if let warning = gate.breachWarning {
            InteractiveProgress.write("Warning: \(warning)\n", to: .standardError)
        }
        if !isVectorRoute, let fault = gate.hardFault {
            InteractiveProgress.write("Warning: \(fault.localizedDescription)\n", to: .standardError)
        }
        if isVectorRoute {
            try await requireVectorReady(wax: wax)
        }

        let actionOrchestrator = ActionOrchestrator(wax: wax)

        if json {
            var results = try await performUnifiedSearch(db: db, wax: wax, route: route)
            if let fault = gate.hardFault {
                results["arenaFault"] = fault.localizedDescription
            }
            if let warning = gate.breachWarning {
                results["breachWarning"] = warning
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } else {
            try await runInteractiveSearch(db: db, wax: wax, route: route)
        }
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(command: fullCommand, toolName: "search", durationMs: duration)
        
        try await wax.close()
    }

    private func performUnifiedSearch(db: Database, wax: WaxStore, route: SearchRoute) async throws -> [String: Any] {
        switch route {
        case .vector(let semanticQuery):
            var payload = try await vectorPayload(db: db, wax: wax, query: semanticQuery)
            if strict {
                payload["warning"] = "strict_ignored"
                payload["message"] = "--strict applies to lexical file/symbol/grep match only; vector meaning search does not AND terms."
            }
            return payload

        case .lexical(let pattern, let includeGrep, let allowVectorFallback):
            let useAnd = strict || allowVectorFallback
            let files = try db.getFilesLike(pattern: pattern, strict: useAnd)
            let symbols = try db.getSymbolsLike(name: pattern, strict: useAnd)
            let textMatches: [[String: Any]] = includeGrep
                ? try await performGrepSearch(db: db, pattern: pattern)
                : []

            let useful = !files.isEmpty || !symbols.isEmpty || !textMatches.isEmpty
            if !useful && allowVectorFallback {
                try await requireVectorReady(wax: wax)
                var payload = try await vectorPayload(db: db, wax: wax, query: pattern)
                payload["fallback"] = "vector"
                payload["message"] = "No AND lexical matches for multi-word identifier query; fell back to vector search."
                return payload
            }

            var results: [String: Any] = [:]
            results["files"] = files.prefix(limit).map { ["path": $0.path, "language": $0.language] }
            results["symbols"] = symbols.prefix(limit).map {
                ["name": $0.qualifiedName, "kind": "\($0.kind)", "file": $0.filePath]
            }
            if includeGrep {
                results["textMatches"] = textMatches
            }
            return results
        }
    }

    private func runInteractiveSearch(db: Database, wax: WaxStore, route: SearchRoute) async throws {
        switch route {
        case .vector(let semanticQuery):
            if strict {
                print("Warning: --strict is ignored for vector meaning search (applies to lexical match only).")
            }
            try await printVectorResults(db: db, wax: wax, query: semanticQuery)

        case .lexical(let pattern, let includeGrep, let allowVectorFallback):
            let useAnd = strict || allowVectorFallback
            let files = try db.getFilesLike(pattern: pattern, strict: useAnd)
            let symbols = try db.getSymbolsLike(name: pattern, strict: useAnd)

            if !files.isEmpty {
                print("📄 Found \(min(files.count, limit)) file matches:")
                for file in files.prefix(limit) {
                    print("  - \(file.path) (\(file.language))")
                }
            }

            if !symbols.isEmpty {
                print("\n🔶 Found \(min(symbols.count, limit)) symbol matches:")
                for symbol in symbols.prefix(limit) {
                    print("  - \(symbol.qualifiedName) (\(symbol.kind)) in \(symbol.filePath)")
                }
            }

            var textEmpty = true
            if includeGrep {
                print("\n🔍 Found text matches:")
                let textResults = try await performGrepSearch(db: db, pattern: pattern)
                textEmpty = textResults.isEmpty
                for match in textResults {
                    print("\n--- \(match["file"]!) ---")
                    if let snippet = match["snippet"] as? String {
                        print(snippet)
                    }
                }
            }

            let useful = !files.isEmpty || !symbols.isEmpty || (includeGrep && !textEmpty)
            if !useful && allowVectorFallback {
                print("No AND lexical matches; falling back to semantic search...")
                try await requireVectorReady(wax: wax)
                try await printVectorResults(db: db, wax: wax, query: pattern)
            } else if !useful {
                print("No file or symbol matches for '\(pattern)'.")
            }
        }
    }

    private func vectorPayload(db: Database, wax: WaxStore, query: String) async throws -> [String: Any] {
        let waxResults = try await wax.search(query, limit: limit)
        return [
            "semanticMatches": waxResults.map { result in
                // Line ranges make hits actionable without a resolution round trip.
                var row: [String: Any] = [
                    "symbol": result.symbol,
                    "score": result.score,
                    "file": result.file,
                ]
                if let sym = try? db.getSymbols(qualifiedName: result.symbol).first {
                    row["startLine"] = sym.startLine
                    row["endLine"] = sym.endLine
                    row["kind"] = "\(sym.kind)"
                }
                return row
            }
        ]
    }

    private func printVectorResults(db: Database, wax: WaxStore, query: String) async throws {
        print("🧠 Performing Semantic Search...")
        guard await wax.isAvailable() else {
            print("Error: Semantic store unavailable. Run 'cckit index .' to rebuild.")
            throw ExitCode.failure
        }
        let waxResults = try await wax.search(query, limit: limit)

        if waxResults.isEmpty {
            print("No semantic matches. If you recently upgraded cckit, run 'cckit index .' to rebuild the vector index.")
            return
        }
        
        for res in waxResults {
            if let sym = try db.getSymbols(qualifiedName: res.symbol).first {
                print("\n--- \(sym.qualifiedName) (\(sym.kind)) ---")
                print("File: \(sym.filePath)")
                print("Match: \(res.preview)")
            } else {
                print("\n--- \(res.symbol) ---")
                print("File: \(res.file)")
                print("Match: \(res.preview)")
            }
        }
    }

    private func requireVectorReady(wax: WaxStore) async throws {
        do {
            try WaxEmbedderIdentity.requireCurrent()
            try await wax.requireEmbeddings()
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func performGrepSearch(db: Database, pattern: String) async throws -> [[String: Any]] {
        let files = try db.getAllFiles()
        var matches: [[String: Any]] = []
        
        let terms = regex ? [pattern] : pattern.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if terms.isEmpty { return [] }

        let regexes = terms.compactMap { term -> NSRegularExpression? in
            let escaped = regex ? term : NSRegularExpression.escapedPattern(for: term)
            return try? NSRegularExpression(pattern: escaped, options: .caseInsensitive)
        }
        
        for file in files {
            guard let content = try? String(contentsOfFile: file.path, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            
            for (index, line) in lines.enumerated() {
                let range = NSRange(location: 0, length: line.utf16.count)
                
                let matchCount = regexes.filter { re in
                    re.firstMatch(in: line, options: [], range: range) != nil
                }.count
                
                let isMatch = strict ? (matchCount == regexes.count) : (matchCount > 0)

                if isMatch {
                    let start = max(0, index - 1)
                    let end = min(lines.count - 1, index + 1)
                    var snippet = ""
                    for i in start...end {
                        let prefix = (i == index) ? "> " : "  "
                        snippet += "\(prefix)L\(i+1): \(lines[i].trimmingCharacters(in: .whitespaces))\n"
                    }
                    
                    matches.append([
                        "file": file.path,
                        "line": index + 1,
                        "content": line.trimmingCharacters(in: .whitespaces),
                        "snippet": snippet
                    ])
                    break
                }
            }
            if matches.count >= limit { break }
        }
        return matches
    }
}
