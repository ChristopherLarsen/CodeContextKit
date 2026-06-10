import ArgumentParser
import Foundation
import CodeContextKitStorage
import CodeContextKitContext
import CodeContextKitRetrieval

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
        let wax = try await WaxStore(path: ".cckit/repo.wax")
        let actionOrchestrator = ActionOrchestrator(db: db, wax: wax)
        
        let builder = RepoMapBuilder(db: db, counter: { text in await wax.countTokens(text) })
        let delegate = CommandLineRepoMapProgressDelegate()
        let map = try await builder.buildMap(budget: budget, focusTerms: focus, delegate: delegate, verbose: verbose)
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let tokens = await wax.countTokens(map)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(command: fullCommand, toolName: "Map Builder", durationMs: duration, tokensUsed: tokens)
        
        print("\n" + map)
        try await wax.close()
    }
}

struct CommandLineRepoMapProgressDelegate: RepoMapProgressDelegate {
    func repoMapDidProgress(completed: Int, total: Int, currentFile: String) {
        let percent = Int(Double(completed) / Double(total) * 100)
        print("\rRanking symbols: \(percent)% [\(completed)/\(total)] \(currentFile.split(separator: "/").last ?? "")", terminator: "")
        fflush(stdout)
    }
}
