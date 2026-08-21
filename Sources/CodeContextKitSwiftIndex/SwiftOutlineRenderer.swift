import Foundation
import CodeContextKitCore

public struct SwiftOutlineRenderer: OutlineRendering {
    public init() {}

    public func render(filePath: String, symbols: [SymbolRecord], options: OutlineOptions = .default) -> String {
        OutlineAssembler.render(symbols: symbols, options: options) { symbol in
            max(0, symbol.qualifiedName.split(separator: ".").count - 1)
        }
    }
}
