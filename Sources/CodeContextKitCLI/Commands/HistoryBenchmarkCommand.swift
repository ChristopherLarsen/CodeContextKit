import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitContext
import CodeContextKitRetrieval

struct HistoryBenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history-benchmark",
        abstract: "Sample git history to graph map compression versus naive file reads."
    )

    @Option(name: .shortAndLong, help: "Path to the target git repository.")
    var path: String

    @Option(name: .shortAndLong, help: "Focus term for mapping.")
    var focus: String = ""

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

        let status = try runShell("git status", at: repoURL.path)
        guard status.contains("On branch") || status.contains("HEAD detached") else {
            print("Error: Target path is not a git repository.")
            throw ExitCode.failure
        }

        let originalBranch = try runShell("git rev-parse --abbrev-ref HEAD", at: repoURL.path)
        print("Original branch: \(originalBranch)")

        let logOutput = try runShell("git log --format='%H|%s' -n \(limit)", at: repoURL.path)
        let lines = logOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var commits = lines.map { line -> (hash: String, message: String) in
            let parts = line.split(separator: "|", maxSplits: 1)
            return (hash: String(parts[0]), message: String(parts.count > 1 ? parts[1] : ""))
        }
        commits.reverse()

        var results: [[String: Any]] = []
        let estimator = TokenEstimator.shared

        for (i, commit) in commits.enumerated() {
            print("\n--- Cycle \(i + 1)/\(commits.count): Checkout \(commit.hash.prefix(7)) ---")
            _ = try runShell("git checkout \(commit.hash)", at: repoURL.path)

            let tempDBPath = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
            let tempWaxPath = NSTemporaryDirectory() + UUID().uuidString + ".wax"

            let db = try Database(path: tempDBPath)
            let wax = try await WaxStore(path: tempWaxPath)
            let indexer = Indexer(db: db, wax: wax)

            print("Indexing...")
            try await indexer.index(at: repoURL.path)

            var totalFiles = 0
            var naiveTokens = 0
            if let enumerator = FileManager.default.enumerator(
                at: repoURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if ["swift", "kt", "kts", "java", "js", "ts", "tsx", "py"].contains(fileURL.pathExtension) {
                        totalFiles += 1
                        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                            naiveTokens += estimator.estimate(content)
                        }
                    }
                }
            }

            let mapFocus = focus.isEmpty ? commit.message : focus
            print("Mapping...")
            let builder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
            let map = try await builder.buildMap(budget: budget, focusTerms: mapFocus)
            let mapTokens = await wax.countTokens(map)
            let isFocusPreserved = mapFocus.isEmpty
                || map.lowercased().contains(mapFocus.lowercased())

            results.append([
                "cycle": i + 1,
                "hash": commit.hash,
                "message": commit.message,
                "totalFiles": totalFiles,
                "naiveTokens": naiveTokens,
                "mapTokens": mapTokens,
                "focusPreserved": isFocusPreserved,
                "compressionRatio": naiveTokens > 0 ? Double(naiveTokens) / Double(max(mapTokens, 1)) : 0,
            ])
            print("Naive Tokens: \(naiveTokens) | Map Tokens: \(mapTokens) | Preserved: \(isFocusPreserved)")

            try await wax.close()
            try? FileManager.default.removeItem(atPath: tempDBPath)
            try? FileManager.default.removeItem(atPath: tempWaxPath)
        }

        print("\nRestoring original state...")
        let restoreRef = originalBranch == "HEAD" ? "main" : originalBranch
        _ = try runShell("git checkout \(restoreRef)", at: repoURL.path)

        let jsonData = try JSONSerialization.data(
            withJSONObject: ["results": results],
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: URL(fileURLWithPath: output))
        print("Benchmark complete. Results written to \(output)")
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
