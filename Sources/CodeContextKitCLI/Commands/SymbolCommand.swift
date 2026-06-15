import ArgumentParser
import Foundation
import CodeContextKitCore
import CodeContextKitStorage

struct SymbolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "symbol",
        abstract: "Retrieves a symbol by exact name."
    )

    @Argument(help: "The qualified symbol name.")
    var name: String

    @Flag(help: "Output in JSON format.")
    var json: Bool = false

    func run() async throws {
        let dbPath = ".cckit/index.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("Error: Index not found. Run 'cckit index' first.")
            throw ExitCode.failure
        }
        
        let db = try Database(path: dbPath)
        let symbols = try db.getSymbols(qualifiedName: name)
        
        if symbols.isEmpty {
            print("No symbol found for '\(name)'.")
            return
        }
        
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(symbols)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } else {
            for symbol in symbols {
                print("Symbol: \(symbol.qualifiedName)")
                print("Kind: \(symbol.kind)")
                print("File: \(symbol.filePath):\(symbol.startLine)-\(symbol.endLine)")
                print("Signature: \(symbol.signature)")
                if let doc = symbol.docComment {
                    print("Docs: \(doc)")
                }
                print("Tokens (est): \(symbol.estimatedTokens)")
                print("-" * 20)
            }
        }
    }
}

private func *(lhs: String, rhs: Int) -> String {
    String(repeating: lhs, count: rhs)
}
