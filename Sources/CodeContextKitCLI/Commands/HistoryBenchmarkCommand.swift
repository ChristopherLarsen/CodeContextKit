import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitContext
import CodeContextKitRetrieval

struct HistoryBenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history-benchmark",
        abstract: "Runs context generation across a repository's git history to graph efficiency."
    )
    
    @Option(name: .shortAndLong, help: "Path to the target git repository.")
    var path: String
    
    @Option(name: .shortAndLong, help: "Focus term for mapping.")
    var focus: String
    
    @Option(name: .shortAndLong, help: "Target token budget for the map.")
    var budget: Int = 2000
    
    @Option(name: .shortAndLong, help: "Number of commits to sample.")
    var limit: Int = 20
    
    @Option(name: .shortAndLong, help: "Output JSON file path.")
    var output: String = "benchmark_results.json"
    
    mutating func run() async throws {
        let absolutePath = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let repoURL = URL(fileURLWithPath: absolutePath)
        print("Benchmarking repository at: \(repoURL.path)")
        
        // Ensure it's a git repo
        let status = try runShell("git status", at: repoURL.path)
        guard status.contains("On branch") || status.contains("HEAD detached") else {
            print("Error: Target path is not a git repository.")
            throw ExitCode.failure
        }
        
        // Save current branch to restore later
        let originalBranch = try runShell("git rev-parse --abbrev-ref HEAD", at: repoURL.path)
        print("Original branch: \(originalBranch)")
        
        // Get commits
        let logOutput = try runShell("git log --format='%H|%s' -n \(limit)", at: repoURL.path)
        let lines = logOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var commits = lines.map { line -> (hash: String, message: String) in
            let parts = line.split(separator: "|", maxSplits: 1)
            return (hash: String(parts[0]), message: String(parts.count > 1 ? parts[1] : ""))
        }
        commits.reverse() // Oldest to newest
        
        var results: [[String: Any]] = []
        let estimator = TokenEstimator.shared
        
        for (i, commit) in commits.enumerated() {
            print("\n--- Cycle \(i + 1)/\(commits.count): Checkout \(commit.hash.prefix(7)) ---")
            _ = try runShell("git checkout \(commit.hash)", at: repoURL.path)
            
            // Setup isolated DB for this commit
            let tempDBPath = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
            let tempWaxPath = NSTemporaryDirectory() + UUID().uuidString + ".wax"
            
            let db = try Database(path: tempDBPath)
            let wax = try await WaxStore(path: tempWaxPath)
            let indexer = Indexer(db: db, wax: wax)
            
            print("Indexing...")
            try await indexer.index(at: repoURL.path)
            
            // Calculate Naive Stats
            var totalFiles = 0
            var naiveTokens = 0
            if let enumerator = FileManager.default.enumerator(at: repoURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension == "swift" {
                        totalFiles += 1
                        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                            naiveTokens += estimator.estimate(content)
                        }
                    }
                }
            }
            
            // Generate CCKit Map
            print("Mapping...")
            let builder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
            let map = try await builder.buildMap(budget: budget, focusTerms: focus)
            let mapTokens = await wax.countTokens(map)
            
            // Quality Check: Does the map contain the focus term?
            let isFocusPreserved = map.lowercased().contains(focus.lowercased())
            
            let result: [String: Any] = [
                "cycle": i + 1,
                "hash": commit.hash,
                "message": commit.message,
                "totalFiles": totalFiles,
                "naiveTokens": naiveTokens,
                "mapTokens": mapTokens,
                "focusPreserved": isFocusPreserved,
                "compressionRatio": naiveTokens > 0 ? Double(naiveTokens) / Double(mapTokens) : 0
            ]
            results.append(result)
            
            print("Naive Tokens: \(naiveTokens) | Map Tokens: \(mapTokens) | Preserved: \(isFocusPreserved)")
            
            try await wax.close()
            
            // Cleanup isolated DBs
            try? FileManager.default.removeItem(atPath: tempDBPath)
            try? FileManager.default.removeItem(atPath: tempWaxPath)
        }
        
        // Restore branch
        print("\nRestoring original state...")
        _ = try runShell("git checkout \(originalBranch == "HEAD" ? "main" : originalBranch)", at: repoURL.path)
        
        // Write JSON
        let jsonData = try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
        try jsonData.write(to: URL(fileURLWithPath: output))
        print("✅ Benchmark complete. Results written to \(output)")
    }
    
    private func runShell(_ command: String, at path: String) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.currentDirectoryURL = URL(fileURLWithPath: path)
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
