import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitContext

struct OutlineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outline",
        abstract: "Prints a structural outline of a source file."
    )

    @Argument(help: "The source file to outline.")
    var filePath: String

    @Flag(name: .long, help: "Include doc comments.")
    var docs: Bool = false

    @Flag(name: .long, help: "Full member lists, docs, no size cap.")
    var full: Bool = false

    func run() async throws {
        let startTime = Date()
        let url = URL(fileURLWithPath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)

        let splitter = SplitterRouter().splitter(for: filePath)
        let (symbols, _) = splitter.extractSymbols(content: content, filePath: filePath)
        let renderer = OutlineRendererRegistry().renderer(for: filePath)
        let options: OutlineOptions
        if full {
            options = .full
        } else if docs {
            options = OutlineOptions(includeDocs: true)
        } else {
            options = .default
        }
        let outline = renderer.render(filePath: filePath, symbols: symbols, options: options)

        let freshness = IndexFreshness.check(repoRoot: ".")
        if let warning = freshness.softWarning {
            InteractiveProgress.write(warning + "\n", to: .standardError)
        }
        print(outline)
        // Machine-readable trailing line for the MCP shim (CCKIT_CALLER=mcp).
        if ProcessInfo.processInfo.environment["CCKIT_CALLER"] == "mcp" {
            let delivered = TokenEstimator.shared.estimate(outline)
            let source = TokenEstimator.shared.estimate(content)
            print("OUTLINE_STATS {\"deliveredTokens\":\(delivered),\"sourceWholeFileTokens\":\(source)}")
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        let fullCommand = "cckit " + CommandLine.arguments.dropFirst().joined(separator: " ")
        let actionOrchestrator = ActionOrchestrator(repoRoot: ".")
        try await actionOrchestrator.recordCLIAction(
            command: fullCommand,
            toolName: "outline",
            durationMs: duration,
            tokensUsed: TokenEstimator.shared.estimate(outline),
            sourceWholeFileTokens: TokenEstimator.shared.estimate(content)
        )
    }
}
