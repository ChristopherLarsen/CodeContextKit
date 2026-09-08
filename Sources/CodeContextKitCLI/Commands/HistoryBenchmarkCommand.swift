import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitContext
import CodeContextKitRetrieval

struct HistoryBenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history-benchmark",
        abstract: "Sample git history to graph pack tokens and identifier recall versus naive file reads."
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

        let originalHead = try runShell("git rev-parse HEAD", at: repoURL.path)
        let originalRef = originalHead
        print("Original HEAD: \(originalRef)")

        let logOutput = try runShell("git log --format='%H|%s' -n \(limit)", at: repoURL.path)
        let lines = logOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var commits = lines.map { line -> (hash: String, message: String) in
            let parts = line.split(separator: "|", maxSplits: 1)
            return (hash: String(parts[0]), message: String(parts.count > 1 ? parts[1] : ""))
        }
        commits.reverse()

        var results: [[String: Any]] = []
        let estimator = TokenEstimator.shared

        defer {
            _ = try? runShell("git checkout \(originalRef)", at: repoURL.path)
        }

        for (i, commit) in commits.enumerated() {
            print("\n--- Cycle \(i + 1)/\(commits.count): Checkout \(commit.hash.prefix(7)) ---")
            _ = try runShell("git checkout \(commit.hash)", at: repoURL.path)

            let tempDBPath = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
            let tempWaxPath = NSTemporaryDirectory() + UUID().uuidString + ".wax"

            let db = try Database(path: tempDBPath)
            let wax = try await WaxStore(path: tempWaxPath)
            let indexer = Indexer(db: db, wax: wax)

            print("Indexing...")
            _ = try await indexer.index(at: repoURL.path)

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

            let packTask = focus.isEmpty ? commit.message : focus
            print("Packing...")
            let packer = ContextPacker(db: db, wax: wax, rootPath: repoURL.path)
            let pack = try await packer.pack(task: packTask, budget: budget, mode: .surgical, mapBudget: 0)
            let packTokens = pack.deliveredTokens
            let required = SemanticIndexPolicy.retrievalQueries(in: packTask)
            let needles = required.qualified + required.leaves
            let recalled = needles.filter { needle in
                pack.deliveredTargetIDs.contains(where: { $0.contains(needle) })
                    || pack.packet.contains(needle)
            }
            let fileRecall = needles.isEmpty
                ? 1.0
                : Double(recalled.count) / Double(needles.count)

            results.append([
                "cycle": i + 1,
                "hash": commit.hash,
                "message": commit.message,
                "totalFiles": totalFiles,
                "naiveTokens": naiveTokens,
                "packTokens": packTokens,
                "primaryCount": pack.primaryCount,
                "requiredTargetCount": pack.requiredTargetIDs.count,
                "deliveredTargetCount": pack.deliveredTargetIDs.count,
                "fileRecall": fileRecall,
                "identifierRecall": fileRecall,
            ])
            print(
                "Naive Tokens: \(naiveTokens) | Pack Tokens: \(packTokens) | "
                    + "Recall: \(recalled.count)/\(max(needles.count, 1))"
            )

            try await wax.close()
            try? FileManager.default.removeItem(atPath: tempDBPath)
            try? FileManager.default.removeItem(atPath: tempWaxPath)
        }

        _ = try runShell("git checkout \(originalRef)", at: repoURL.path)
        print("Restored \(originalRef)")

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
        // Drain to EOF before waiting; the reverse order deadlocks once the
        // child fills the ~64 KB pipe buffer (e.g. a large `git log -p`).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "HistoryBenchmark",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Command failed (\(task.terminationStatus)): \(command)\n\(text)"]
            )
        }
        return text
    }
}
