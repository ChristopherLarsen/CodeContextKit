import Foundation
import CodeContextKitCore

public struct KotlinOutlineRenderer: OutlineRendering {
    public init() {}

    public func render(filePath: String, symbols: [SymbolRecord]) -> String {
        var output = ""
        let sortedSymbols = symbols.sorted { $0.startLine < $1.startLine }

        for symbol in sortedSymbols {
            let indentationCount = enclosingTypeDepth(symbol.enclosingType)
            let indentation = String(repeating: "  ", count: indentationCount)

            if let doc = symbol.docComment, !doc.isEmpty {
                for line in doc.components(separatedBy: .newlines) {
                    output += "\(indentation)/// \(line)\n"
                }
            }

            output += "\(indentation)\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]\n"
        }

        return output
    }

    private func enclosingTypeDepth(_ enclosingType: String?) -> Int {
        guard let enclosingType, !enclosingType.isEmpty else { return 0 }

        // Kotlin extraction stores `enclosingType` as a type-only chain, never as
        // a package-qualified name. Outline indentation depends on that contract.
        return enclosingType.split(separator: ".").count
    }
}
