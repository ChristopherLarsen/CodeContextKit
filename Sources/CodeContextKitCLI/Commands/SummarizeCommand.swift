import ArgumentParser
import Foundation
import CodeContextKitStorage
import CodeContextKitContext

struct SummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Generates project summaries and DNA for agent memory files."
    )

    @Flag(name: .shortAndLong, help: "Output specifically for CLAUDE.md/GEMINI.md memory files.")
    var memory: Bool = false

    func run() async throws {
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }
        
        let db = try Database(path: dbPath)
        let summarizer = Summarizer(db: db)
        
        let dna = try summarizer.generateProjectDNA()
        print(dna)
    }
}
