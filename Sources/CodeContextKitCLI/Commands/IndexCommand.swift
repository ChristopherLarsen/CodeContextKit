import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitSwiftIndex
import CodeContextKitStorage
import CodeContextKitRetrieval
import CodeContextKitContext

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Indexes a repository."
    )

    @Argument(help: "The directory to index.")
    var path: String = "."

    @Flag(help: "Clean the index before indexing.")
    var clean: Bool = false

    @Option(help: "Glob patterns to include.")
    var include: [String] = []

    @Option(help: "Glob patterns to exclude.")
    var exclude: [String] = []

    @Option(help: "Folder paths or names to exclude from indexing. Saved to .cckit/config.json when set.")
    var excludeFolder: [String] = []

    @Option(help: "Folder paths or names to index even when ignored by .gitignore. Saved to .cckit/config.json when set.")
    var includeFolder: [String] = []

    @Flag(help: "Print index statistics.")
    var stats: Bool = false

    @Flag(help: "Include Gradle .kts build scripts.")
    var includeBuildScripts: Bool = false

    @Flag(help: "Include generated Gradle/Kotlin source directories.")
    var includeGenerated: Bool = false

    func run() async throws {
        let startTime = Date()
        let dbPath = ".cckit/index.sqlite"
        let waxPath = ".cckit/repo.wax"
        
        if clean {
            if FileManager.default.fileExists(atPath: dbPath) {
                try FileManager.default.removeItem(atPath: dbPath)
            }
            if FileManager.default.fileExists(atPath: waxPath) {
                try FileManager.default.removeItem(atPath: waxPath)
            }
        }
        
        let db = try Database(path: dbPath)
        let wax = try await WaxStore(path: waxPath)
        let actionOrchestrator = ActionOrchestrator(db: db, wax: wax)
        let indexer = Indexer(db: db, wax: wax)
        let absolutePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if !excludeFolder.isEmpty || !includeFolder.isEmpty {
            var settings = ProjectSettings.load(projectRoot: absolutePath)
            settings.excludedFolders = Array(Set(settings.excludedFolders + excludeFolder)).sorted()
            settings.includedFolders = Array(Set(settings.includedFolders + includeFolder)).sorted()
            try settings.save(projectRoot: absolutePath)
        }
        
        print("Indexing \(path)...")
        try await indexer.index(
            at: path,
            include: include,
            exclude: exclude,
            includeBuildScripts: includeBuildScripts,
            includeGenerated: includeGenerated,
            delegate: CommandLineProgressDelegate()
        )
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        try await actionOrchestrator.recordCLIAction(command: "index \(path)\(clean ? " --clean" : "")", toolName: "Indexer", durationMs: duration)
        
        try await wax.close()
    }
}

struct CommandLineProgressDelegate: IndexerProgressDelegate {
    func indexerDidStart(totalFiles: Int) {
        print("Starting indexing of \(totalFiles) files...")
    }
    
    func indexerDidProgress(completedFiles: Int, totalFiles: Int, currentFile: String) {
        let percent = totalFiles > 0 ? (completedFiles * 100 / totalFiles) : 0
        print("[\(percent)%] \(currentFile)")
    }
    
    func indexerDidFinish(updated: Int, skipped: Int, totalSymbols: Int) {
        print("Indexing complete. Updated: \(updated), Skipped: \(skipped), Symbols: \(totalSymbols)")
    }
    
    func indexerDidFail(error: Error) {
        print("Indexing failed: \(error.localizedDescription)")
    }
}
