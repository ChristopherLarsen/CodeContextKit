import Foundation

public struct RegexSplitter: CodeSplitter, Sendable {
    private let language: String
    private let patterns: [SymbolRecord.Kind: String]
    private let estimator = TokenEstimator()

    public init(language: String) {
        self.language = language
        switch language {
        case "js", "ts", "javascript", "typescript", "jsx", "tsx":
            self.patterns = [
                .class: #"\bclass\s+([a-zA-Z0-9_]+)"#,
                .function: #"\b(?:function|async\s+function)\s+([a-zA-Z0-9_]+)|(?:const|let|var)\s+([a-zA-Z0-9_]+)\s*=\s*(?:async\s*)?\(.*?\)\s*=>"#,
                .interface: #"\binterface\s+([a-zA-Z0-9_]+)"#,
                .property: #"\b(?:const|let|var)\s+([a-zA-Z0-9_]+)\s*="#
            ]
        case "css", "scss", "less":
            self.patterns = [
                .style: #"^\s*([.#]?[a-zA-Z0-9_-]+)\s*\{"#
            ]
        case "python", "py":
            self.patterns = [
                .class: #"^class\s+([a-zA-Z0-9_]+)"#,
                .function: #"^def\s+([a-zA-Z0-9_]+)"#
            ]
        case "java":
            self.patterns = [
                .class: #"\bclass\s+([a-zA-Z0-9_]+)"#,
                .interface: #"\binterface\s+([a-zA-Z0-9_]+)"#,
                .method: #"\b(?:public|protected|private|static|\s) +[\w\<\>\[\]]+\s+([a-zA-Z0-9_]+)\s*\("#
            ]
        default:
            self.patterns = [:]
        }
    }

    public func extractSymbols(content: String, filePath: String) -> ([SymbolRecord], [SymbolRecord.Reference]) {
        let lines = content.components(separatedBy: .newlines)
        var symbols: [SymbolRecord] = []
        var seenOnLine: Set<String> = [] // Track seen symbols on current line to avoid duplicates
        
        for (index, line) in lines.enumerated() {
            seenOnLine.removeAll()
            for (kind, pattern) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(location: 0, length: line.utf16.count)
                    if let match = regex.firstMatch(in: line, options: [], range: range) {
                        var name: String?
                        for i in (1..<match.numberOfRanges).reversed() {
                            let groupRange = match.range(at: i)
                            if groupRange.location != NSNotFound, let r = Range(groupRange, in: line) {
                                name = String(line[r])
                                break
                            }
                        }
                        
                        if let name = name, !seenOnLine.contains(name) {
                            seenOnLine.insert(name)
                            symbols.append(SymbolRecord(
                                kind: kind,
                                name: name,
                                qualifiedName: name,
                                signature: line.trimmingCharacters(in: .whitespaces),
                                filePath: filePath,
                                startLine: index + 1,
                                endLine: index + 1, // Regex base is line-based for now
                                estimatedTokens: estimator.estimate(line)
                            ))
                        }
                    }
                }
            }
        }
        
        return (symbols, [])
    }
}
