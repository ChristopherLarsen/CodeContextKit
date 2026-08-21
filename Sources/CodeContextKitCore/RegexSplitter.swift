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
            self.patterns = [:]
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
        if language == "css" || language == "scss" || language == "less" {
            return (extractCSS(content: content, filePath: filePath), [])
        }

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

    /// Selectors (including `:root`) span to the matching `}`; custom properties are first-class.
    private func extractCSS(content: String, filePath: String) -> [SymbolRecord] {
        let lines = content.components(separatedBy: .newlines)
        let selectorRegex = try? NSRegularExpression(
            pattern: #"^\s*(:root|[.#]?[a-zA-Z0-9_-]+)\s*\{"#
        )
        let customPropertyRegex = try? NSRegularExpression(
            pattern: #"^\s*(--[a-zA-Z0-9_-]+)\s*:"#
        )
        var symbols: [SymbolRecord] = []
        var seenOnLine: Set<String> = []

        for (index, line) in lines.enumerated() {
            seenOnLine.removeAll()
            let utf16Count = line.utf16.count
            let range = NSRange(location: 0, length: utf16Count)

            if let regex = selectorRegex,
               let match = regex.firstMatch(in: line, options: [], range: range),
               let name = firstCapture(in: line, match: match) {
                let end = closingBraceLine(startingAt: index, lines: lines)
                symbols.append(SymbolRecord(
                    kind: .style,
                    name: name,
                    qualifiedName: name,
                    signature: line.trimmingCharacters(in: .whitespaces),
                    filePath: filePath,
                    startLine: index + 1,
                    endLine: end + 1,
                    estimatedTokens: estimator.estimate(lines[index...end].joined(separator: "\n"))
                ))
                seenOnLine.insert(name)
            }

            if let regex = customPropertyRegex,
               let match = regex.firstMatch(in: line, options: [], range: range),
               let name = firstCapture(in: line, match: match),
               !seenOnLine.contains(name) {
                symbols.append(SymbolRecord(
                    kind: .property,
                    name: name,
                    qualifiedName: name,
                    signature: line.trimmingCharacters(in: .whitespaces),
                    filePath: filePath,
                    startLine: index + 1,
                    endLine: index + 1,
                    estimatedTokens: estimator.estimate(line)
                ))
            }
        }
        return symbols
    }

    private func firstCapture(in line: String, match: NSTextCheckingResult) -> String? {
        for i in 1..<match.numberOfRanges {
            let groupRange = match.range(at: i)
            if groupRange.location != NSNotFound, let r = Range(groupRange, in: line) {
                return String(line[r])
            }
        }
        return nil
    }

    private func closingBraceLine(startingAt start: Int, lines: [String]) -> Int {
        var depth = 0
        var seenOpen = false
        for index in start..<lines.count {
            for ch in lines[index] {
                if ch == "{" {
                    depth += 1
                    seenOpen = true
                } else if ch == "}" {
                    depth -= 1
                    if seenOpen && depth <= 0 {
                        return index
                    }
                }
            }
        }
        return start
    }
}
