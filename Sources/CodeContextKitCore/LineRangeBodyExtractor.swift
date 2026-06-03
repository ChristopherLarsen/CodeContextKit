import Foundation

public enum LineRangeBodyExtractor {
    public static func body(for symbol: SymbolRecord, content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let start = max(0, symbol.startLine - 1)
        let end = min(lines.count, symbol.endLine)

        guard start < lines.count, start < end else {
            return ""
        }

        return lines[start..<end].joined(separator: "\n")
    }
}
