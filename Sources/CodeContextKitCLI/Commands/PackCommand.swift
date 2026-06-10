import ArgumentParser
import Foundation
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

struct PackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Creates a model-ready context packet."
    )

    @Option(help: "The task description.")
    var task: String

    @Option(help: "The total token budget.")
    var budget: Int = 12000

    @Option(help: "The output file path.")
    var output: String?

    @Option(help: "The format (markdown or json).")
    var format: String = "markdown"

    @Option(help: "A failure log file to extract context from.")
    var failure: String?

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        let waxPath = ".cckit/repo.wax"
        
        guard FileManager.default.fileExists(atPath: dbPath),
              FileManager.default.fileExists(atPath: waxPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }
        
        let db = try Database(path: dbPath)
        let wax = try await WaxStore(path: waxPath)
        let actionOrchestrator = ActionOrchestrator(db: db, wax: wax)
        let packer = ContextPacker(db: db, wax: wax, rootPath: ".")
        
        let packet = try await packer.pack(task: task, budget: budget, failureLog: failure)
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let tokens = await wax.countTokens(packet)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        try await actionOrchestrator.recordCLIAction(command: fullCommand, toolName: "Context Packer", durationMs: duration, tokensUsed: tokens)

        if let outputPath = output {
            try packet.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("Context packet written to \(outputPath)")
        } else {
            print(packet)
        }
        try await wax.close()
    }
}
