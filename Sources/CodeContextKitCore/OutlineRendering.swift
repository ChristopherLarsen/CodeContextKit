import Foundation

public protocol OutlineRendering: Sendable {
    func render(filePath: String, symbols: [SymbolRecord]) -> String
}

public struct GenericOutlineRenderer: OutlineRendering {
    public init() {}

    public func render(filePath: String, symbols: [SymbolRecord]) -> String {
        var output = ""
        for symbol in symbols.sorted(by: { $0.startLine < $1.startLine }) {
            output += "\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]\n"
        }
        return output
    }
}
