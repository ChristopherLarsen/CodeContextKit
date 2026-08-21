import Foundation

public struct OutlineOptions: Sendable, Equatable {
    public var includeDocs: Bool
    public var maxChars: Int
    public var collapseMemberThreshold: Int

    public static let `default` = OutlineOptions(
        includeDocs: false,
        maxChars: 8_000,
        collapseMemberThreshold: 40
    )

    public static let full = OutlineOptions(
        includeDocs: true,
        maxChars: Int.max,
        collapseMemberThreshold: Int.max
    )

    public init(
        includeDocs: Bool = false,
        maxChars: Int = 8_000,
        collapseMemberThreshold: Int = 40
    ) {
        self.includeDocs = includeDocs
        self.maxChars = maxChars
        self.collapseMemberThreshold = collapseMemberThreshold
    }
}

public protocol OutlineRendering: Sendable {
    func render(filePath: String, symbols: [SymbolRecord], options: OutlineOptions) -> String
}

extension OutlineRendering {
    public func render(filePath: String, symbols: [SymbolRecord]) -> String {
        render(filePath: filePath, symbols: symbols, options: .default)
    }
}

/// Shared outline emission: no docs by default, collapse huge nested types, cap size.
public enum OutlineAssembler: Sendable {
    public static func render(
        symbols: [SymbolRecord],
        options: OutlineOptions = .default,
        indentOf: (SymbolRecord) -> Int = { _ in 0 }
    ) -> String {
        let sorted = symbols.sorted { $0.startLine < $1.startLine }
        let collapsed = collapsedTypeCounts(sorted, threshold: options.collapseMemberThreshold)
        let collapsedKeys = Set(collapsed.keys)

        var lines: [String] = []
        for symbol in sorted {
            if shouldSkipMember(symbol, collapsedKeys: collapsedKeys) {
                continue
            }

            let indent = String(repeating: "  ", count: max(0, indentOf(symbol)))
            if options.includeDocs, let doc = symbol.docComment, !doc.isEmpty {
                for line in doc.components(separatedBy: .newlines) {
                    lines.append("\(indent)/// \(line)")
                }
            }

            var row = "\(indent)\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
            if symbol.kind.isType, let count = collapsed[symbol.qualifiedName] {
                row += "  (\(count) members omitted — pass a nested name or use find_symbol)"
            }
            lines.append(row)
        }

        var output = lines.joined(separator: "\n")
        if !output.isEmpty {
            output += "\n"
        }

        guard options.maxChars != Int.max, output.count > options.maxChars else {
            return output
        }
        let truncated = String(output.prefix(options.maxChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated + "\n… outline truncated. find_symbol a name, or outline --full.\n"
    }

    private static func collapsedTypeCounts(
        _ symbols: [SymbolRecord],
        threshold: Int
    ) -> [String: Int] {
        guard threshold != Int.max else { return [:] }
        let typeQNs = Set(symbols.filter(\.kind.isType).map(\.qualifiedName))
        var counts: [String: Int] = [:]
        for symbol in symbols where !symbol.kind.isType {
            if let parent = parentTypeQualifiedName(symbol, typeQNs: typeQNs) {
                counts[parent, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= threshold }
    }

    private static func shouldSkipMember(
        _ symbol: SymbolRecord,
        collapsedKeys: Set<String>
    ) -> Bool {
        guard !symbol.kind.isType, !collapsedKeys.isEmpty else { return false }
        return parentTypeQualifiedName(symbol, typeQNs: collapsedKeys) != nil
    }

    private static func parentTypeQualifiedName(
        _ symbol: SymbolRecord,
        typeQNs: Set<String>
    ) -> String? {
        if let enclosing = symbol.enclosingType {
            if typeQNs.contains(enclosing) {
                return enclosing
            }
            if let match = typeQNs.first(where: { $0.hasSuffix(".\(enclosing)") }) {
                return match
            }
        }
        let parts = symbol.qualifiedName.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let parent = parts.dropLast().joined(separator: ".")
        return typeQNs.contains(parent) ? parent : nil
    }
}

public struct GenericOutlineRenderer: OutlineRendering {
    public init() {}

    public func render(filePath: String, symbols: [SymbolRecord], options: OutlineOptions = .default) -> String {
        OutlineAssembler.render(symbols: symbols, options: options)
    }
}
