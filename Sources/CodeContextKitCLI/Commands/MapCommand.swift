import ArgumentParser
import Foundation
import Darwin
import CodeContextKitStorage
import CodeContextKitContext
import CodeContextKitCore

struct MapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "map",
        abstract: "Builds a repo map under a token budget."
    )

    @Option(help: "The token budget for the map.")
    var budget: Int = 4096

    @Option(help: "Focus terms for the map.")
    var focus: String?

    @Flag(help: "Include changed files.")
    var changed: Bool = false

    @Option(help: "The base branch for changed files.")
    var base: String = "main"

    @Flag(name: .shortAndLong, help: "Show verbose output to diagnose performance.")
    var verbose: Bool = false

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }

        let db = try Database(path: dbPath)
        let estimator = TokenEstimator.shared
        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")

        let builder = RepoMapBuilder(db: db, counter: { text in estimator.estimate(text) })
        let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
        let delegate: RepoMapProgressDelegate? = InteractiveProgress.shouldEmit(
            verbose: verbose,
            stdoutIsTTY: stdoutIsTTY
        ) ? CommandLineRepoMapProgressDelegate() : nil
        let changedPaths: Set<String>? = changed
            ? MapBaseline.changedPaths(
                repoRoot: FileManager.default.currentDirectoryPath,
                base: base
            )
            : nil
        let map = try await builder.buildMap(
            budget: budget,
            focusTerms: focus,
            changedPaths: changedPaths,
            delegate: delegate,
            verbose: verbose
        )

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let tokens = estimator.estimate(map)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "map",
            durationMs: duration,
            tokensUsed: tokens
        )

        let freshness = IndexFreshness.check(repoRoot: ".")
        if let warning = freshness.softWarning {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        print(map)
    }
}

struct CommandLineRepoMapProgressDelegate: RepoMapProgressDelegate {
    func repoMapDidProgress(completed: Int, total: Int, currentFile: String) {
        let line = InteractiveProgress.rankingLine(
            completed: completed,
            total: total,
            currentFile: currentFile
        )
        InteractiveProgress.write(line, to: .standardError)
    }
}
