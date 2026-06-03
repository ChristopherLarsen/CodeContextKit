import ArgumentParser
import Foundation
import CodeContextKitContext

struct OutlineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outline",
        abstract: "Prints a structural outline of a source file."
    )

    @Argument(help: "The source file to outline.")
    var filePath: String

    func run() async throws {
        let url = URL(fileURLWithPath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        
        let splitter = SplitterRouter().splitter(for: filePath)
        let (symbols, _) = splitter.extractSymbols(content: content, filePath: filePath)
        let renderer = OutlineRendererRegistry().renderer(for: filePath)
        let outline = renderer.render(filePath: filePath, symbols: symbols)
        
        print(outline)
    }
}
