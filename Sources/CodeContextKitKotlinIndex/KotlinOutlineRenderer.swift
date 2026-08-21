import Foundation
import CodeContextKitCore

public struct KotlinOutlineRenderer: OutlineRendering {
    public init() {}

    public func render(filePath: String, symbols: [SymbolRecord], options: OutlineOptions = .default) -> String {
        OutlineAssembler.render(symbols: symbols, options: options) { symbol in
            enclosingTypeDepth(symbol.enclosingType)
        }
    }

    private func enclosingTypeDepth(_ enclosingType: String?) -> Int {
        guard let enclosingType, !enclosingType.isEmpty else { return 0 }

        // Kotlin extraction stores `enclosingType` as a type-only chain, never as
        // a package-qualified name. Outline indentation depends on that contract.
        return enclosingType.split(separator: ".").count
    }
}
