import Foundation
import CodeContextKitCore
import TreeSitter
import TreeSitterKotlin

public struct KotlinSourceFile: CodeSplitter {
    public let filePath: String
    public let content: String
    private let fallback: CodeSplitter?

    public init(filePath: String = "", content: String = "", fallback: CodeSplitter? = nil) {
        self.filePath = filePath
        self.content = content
        self.fallback = fallback ?? KotlinRegexFallbackSplitter()
    }

    public func extractSymbols(content: String, filePath: String) -> ([SymbolRecord], [SymbolRecord.Reference]) {
        guard let parser = ts_parser_new() else {
            return fallback?.extractSymbols(content: content, filePath: filePath) ?? ([], [])
        }
        defer { ts_parser_delete(parser) }

        guard ts_parser_set_language(parser, tree_sitter_kotlin()) else {
            return fallback?.extractSymbols(content: content, filePath: filePath) ?? ([], [])
        }

        let tree = content.withCString { source in
            ts_parser_parse_string(parser, nil, source, UInt32(content.utf8.count))
        }

        guard let tree else {
            return fallback?.extractSymbols(content: content, filePath: filePath) ?? ([], [])
        }
        defer { ts_tree_delete(tree) }

        let visitor = KotlinSymbolVisitor(filePath: filePath, content: content)
        visitor.walk(ts_tree_root_node(tree))
        visitor.finalizeTreeSitterScopes()
        return (visitor.symbols, visitor.references)
    }

    public func extractSymbols() -> ([SymbolRecord], [SymbolRecord.Reference]) {
        extractSymbols(content: content, filePath: filePath)
    }

    public func body(for symbol: SymbolRecord) -> String {
        LineRangeBodyExtractor.body(for: symbol, content: content)
    }
}

private struct KotlinRegexFallbackSplitter: CodeSplitter {
    private let patterns: [SymbolRecord.Kind: String] = [
        .class: #"\bclass\s+([a-zA-Z0-9_]+)"#,
        .interface: #"\binterface\s+([a-zA-Z0-9_]+)"#,
        .function: #"\bfun\s+([a-zA-Z0-9_]+)"#
    ]

    func extractSymbols(content: String, filePath: String) -> ([SymbolRecord], [SymbolRecord.Reference]) {
        let lines = content.components(separatedBy: .newlines)
        var symbols: [SymbolRecord] = []
        let estimator = TokenEstimator()

        for (index, line) in lines.enumerated() {
            for (kind, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(location: 0, length: line.utf16.count)
                guard let match = regex.firstMatch(in: line, range: range),
                      match.numberOfRanges > 1,
                      let nameRange = Range(match.range(at: 1), in: line) else {
                    continue
                }

                let name = String(line[nameRange])
                symbols.append(SymbolRecord(
                    kind: kind,
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

        return (symbols, [])
    }
}

private final class KotlinSymbolVisitor {
    let filePath: String
    let content: String
    let lines: [String]
    var symbols: [SymbolRecord] = []
    var references: [SymbolRecord.Reference] = []

    private var packagePath: String?
    private var typeStack: [String] = []
    private var functionDepth = 0
    private var activeScope: String?
    private var emittedReferences: Set<String> = []
    private let estimator = TokenEstimator()

    init(filePath: String, content: String) {
        self.filePath = filePath
        self.content = content
        self.lines = content.components(separatedBy: .newlines)
    }

    func walk(_ node: TSNode) {
        let kind = nodeKind(node)

        switch kind {
        case KotlinNodeKind.packageHeader:
            packagePath = text(for: node)
                .replacingOccurrences(of: "package", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            walkChildren(node)

        case KotlinNodeKind.classDeclaration:
            visitClassDeclaration(node)

        case KotlinNodeKind.objectDeclaration, KotlinNodeKind.companionObject:
            visitObjectDeclaration(node)

        case KotlinNodeKind.functionDeclaration:
            visitFunctionDeclaration(node)

        case KotlinNodeKind.propertyDeclaration:
            visitPropertyDeclaration(node)
            walkChildren(node)

        case KotlinNodeKind.classParameter:
            visitClassParameter(node)
            walkChildren(node)

        case KotlinNodeKind.primaryConstructor, KotlinNodeKind.secondaryConstructor:
            visitConstructor(node)
            walkChildren(node)

        case KotlinNodeKind.typeAlias:
            visitTypeAlias(node)
            walkChildren(node)

        case KotlinNodeKind.enumEntry:
            visitEnumEntry(node)
            walkChildren(node)

        case KotlinNodeKind.infixExpression:
            if !visitSyntheticInfixDeclaration(node) {
                walkChildren(node)
            }

        case KotlinNodeKind.callExpression:
            addCallReference(node)
            walkChildren(node)

        case KotlinNodeKind.navigationExpression:
            addNavigationReferences(node)
            walkChildren(node)

        case KotlinNodeKind.userType:
            addTypeReferences(node)
            walkChildren(node)

        default:
            walkChildren(node)
        }
    }

    private func walkChildren(_ node: TSNode) {
        let count = ts_node_named_child_count(node)
        if count == 0 { return }
        for index in 0..<count {
            walk(ts_node_named_child(node, index))
        }
    }

    func finalizeTreeSitterScopes() {
        let typeSymbols = symbols
            .filter(\.kind.isKotlinTypeContainer)
            .sorted(by: symbolContainmentOrder)
        guard !typeSymbols.isEmpty else { return }

        symbols = symbols.map { symbol in
            let parentTypes = containingTypes(for: symbol, in: typeSymbols)
            var updated = symbol
            let typePath = parentTypes.map(\.name)

            updated.enclosingType = typePath.isEmpty ? nil : typePath.joined(separator: ".")
            updated.qualifiedName = qualifiedName(for: updated.name, typePath: typePath)
            if updated.kind == .function, !typePath.isEmpty {
                updated.kind = .method
            }
            return updated
        }

        references = references.map { reference in
            var updated = reference
            updated.context = deepestContext(containing: reference)?.qualifiedName ?? updated.context
            return updated
        }
    }

    private func visitClassDeclaration(_ node: TSNode) {
        guard functionDepth == 0 else {
            walkChildren(node)
            return
        }

        let declaration = text(for: node)
        let header = declarationHeaderFromFirstMatch(#"(?<!:)\b(?:enum\s+class|data\s+class|sealed\s+class|value\s+class|class|interface)\b"#, in: declaration)
        guard let name = firstMatch(#"\b(?:class|interface)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: header, group: 1) else {
            walkChildren(node)
            return
        }

        let kind = classKind(for: header)
        addSymbol(
            kind: kind,
            name: cleanIdentifier(name),
            signature: header,
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: accessLevel(in: declaration)
        )

        typeStack.append(cleanIdentifier(name))
        let previousScope = activeScope
        activeScope = qualifiedName(for: cleanIdentifier(name))
        walkChildren(node)
        activeScope = previousScope
        typeStack.removeLast()
    }

    private func visitObjectDeclaration(_ node: TSNode) {
        guard functionDepth == 0 else {
            walkChildren(node)
            return
        }

        let declaration = text(for: node)
        let header = declarationHeaderFromFirstMatch(#"\b(?:companion\s+object|object)\b"#, in: declaration)
        let isCompanion = header.contains("companion object")
        let name = firstMatch(#"\bobject\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: header, group: 1)
            .map(cleanIdentifier) ?? (isCompanion ? "Companion" : "object")

        addSymbol(
            kind: isCompanion ? .companion : .object,
            name: name,
            signature: header,
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: accessLevel(in: declaration)
        )

        typeStack.append(name)
        let previousScope = activeScope
        activeScope = qualifiedName(for: name)
        walkChildren(node)
        activeScope = previousScope
        typeStack.removeLast()
    }

    private func visitFunctionDeclaration(_ node: TSNode) {
        let declaration = text(for: node)
        let parsed = parseFunctionHeader(declaration)

        guard let name = parsed.name else {
            walkChildren(node)
            return
        }

        let shouldIndex = functionDepth == 0
        if shouldIndex {
            let isTest = isTestFunction(name: name, declaration: declaration)
            let kind: SymbolRecord.Kind = isTest ? .test : (typeStack.isEmpty ? .function : .method)
            addSymbol(
                kind: kind,
                name: cleanIdentifier(name),
                signature: parsed.signature,
                node: node,
                docComment: extractKDoc(before: startLine(of: node)),
                accessLevel: accessLevel(in: declaration)
            )
        }

        let previousScope = activeScope
        if shouldIndex {
            activeScope = qualifiedName(for: cleanIdentifier(name))
        }
        functionDepth += 1
        walkChildren(node)
        functionDepth -= 1
        activeScope = previousScope
    }

    private func visitPropertyDeclaration(_ node: TSNode) {
        guard functionDepth == 0 else { return }
        let declaration = text(for: node)
        guard let name = firstMatch(#"\b(?:val|var)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: declaration, group: 1) else {
            return
        }

        addSymbol(
            kind: .property,
            name: cleanIdentifier(name),
            signature: declarationHeader(from: declaration),
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: accessLevel(in: declaration)
        )
    }

    private func visitClassParameter(_ node: TSNode) {
        guard functionDepth == 0, !typeStack.isEmpty else { return }
        let declaration = text(for: node)
        guard let name = firstMatch(#"\b(?:val|var)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: declaration, group: 1) else {
            return
        }

        addSymbol(
            kind: .property,
            name: cleanIdentifier(name),
            signature: declarationHeader(from: declaration),
            node: node,
            docComment: nil,
            accessLevel: accessLevel(in: declaration)
        )
    }

    private func visitConstructor(_ node: TSNode) {
        guard functionDepth == 0, !typeStack.isEmpty else { return }
        let declaration = text(for: node)
        let signature = declarationHeader(from: declaration).isEmpty ? "constructor" : declarationHeader(from: declaration)
        addSymbol(
            kind: .constructor,
            name: "constructor",
            signature: signature,
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: accessLevel(in: declaration)
        )
    }

    private func visitTypeAlias(_ node: TSNode) {
        guard functionDepth == 0 else { return }
        let declaration = text(for: node)
        guard let name = firstMatch(#"\btypealias\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: declaration, group: 1) else {
            return
        }

        addSymbol(
            kind: .typealias,
            name: cleanIdentifier(name),
            signature: declarationHeader(from: declaration),
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: accessLevel(in: declaration)
        )
    }

    private func visitEnumEntry(_ node: TSNode) {
        guard functionDepth == 0, !typeStack.isEmpty else { return }
        let declaration = text(for: node)
        guard let name = firstMatch(#"^\s*(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: declaration, group: 1) else {
            return
        }

        addSymbol(
            kind: .enumEntry,
            name: cleanIdentifier(name),
            signature: declarationHeader(from: declaration),
            node: node,
            docComment: extractKDoc(before: startLine(of: node)),
            accessLevel: nil
        )
    }

    private func visitSyntheticInfixDeclaration(_ node: TSNode) -> Bool {
        guard functionDepth == 0 else { return false }
        let declaration = text(for: node)
        guard declaration.contains("{") else { return false }
        let header = declarationHeader(from: declaration)

        if isSyntheticClassHeader(header) {
            guard let name = firstMatch(#"\b(?:class|interface)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: header, group: 1) else {
                return false
            }

            let cleanName = cleanIdentifier(name)
            addSymbol(
                kind: classKind(for: header + " "),
                name: cleanName,
                signature: header,
                node: node,
                docComment: extractKDoc(before: startLine(of: node)),
                accessLevel: accessLevel(in: header)
            )

            typeStack.append(cleanName)
            let previousScope = activeScope
            activeScope = qualifiedName(for: cleanName)
            walkChildren(node)
            activeScope = previousScope
            typeStack.removeLast()
            return true
        }

        if isSyntheticObjectHeader(header) {
            let isCompanion = header.contains("companion object")
            let name = firstMatch(#"\bobject\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, in: header, group: 1)
                .map(cleanIdentifier) ?? (isCompanion ? "Companion" : "object")

            addSymbol(
                kind: isCompanion ? .companion : .object,
                name: name,
                signature: header,
                node: node,
                docComment: extractKDoc(before: startLine(of: node)),
                accessLevel: accessLevel(in: header)
            )

            typeStack.append(name)
            let previousScope = activeScope
            activeScope = qualifiedName(for: name)
            walkChildren(node)
            activeScope = previousScope
            typeStack.removeLast()
            return true
        }

        return false
    }

    private func addSymbol(
        kind: SymbolRecord.Kind,
        name: String,
        signature: String,
        node: TSNode,
        docComment: String? = nil,
        accessLevel: String? = nil
    ) {
        symbols.append(SymbolRecord(
            kind: kind,
            name: name,
            qualifiedName: qualifiedName(for: name),
            signature: signature,
            filePath: filePath,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            enclosingType: typeStack.isEmpty ? nil : typeStack.joined(separator: "."),
            accessLevel: accessLevel,
            docComment: docComment,
            estimatedTokens: estimator.estimate(text(for: node))
        ))
    }

    private func qualifiedName(for name: String) -> String {
        qualifiedName(for: name, typePath: typeStack)
    }

    private func qualifiedName(for name: String, typePath: [String]) -> String {
        var parts: [String] = []
        if let packagePath, !packagePath.isEmpty {
            parts.append(packagePath)
        }
        parts.append(contentsOf: typePath)
        parts.append(name)
        return parts.joined(separator: ".")
    }

    private func addCallReference(_ node: TSNode) {
        let source = text(for: node)
        if let name = firstMatch(#"(?:^|\.)(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\s*\("#, in: source, group: 1) {
            addReference(cleanIdentifier(name), node: node)
        }
    }

    private func addNavigationReferences(_ node: TSNode) {
        let identifiers = identifiers(in: text(for: node))
        guard identifiers.count > 1 else { return }
        for name in identifiers.dropFirst() {
            addReference(name, node: node)
        }
    }

    private func addTypeReferences(_ node: TSNode) {
        let primitives: Set<String> = ["String", "Int", "Long", "Boolean", "Double", "Float", "Unit", "Any", "Nothing", "List", "Map", "Set"]
        for name in identifiers(in: text(for: node)) where !primitives.contains(name) {
            addReference(name, node: node)
        }
    }

    private func addReference(_ name: String, node: TSNode) {
        guard !name.isEmpty else { return }
        let key = "\(name):\(startLine(of: node)):\(endLine(of: node)):\(activeScope ?? "")"
        guard !emittedReferences.contains(key) else { return }
        emittedReferences.insert(key)
        references.append(SymbolRecord.Reference(
            name: name,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            context: activeScope
        ))
    }

    private func containingTypes(for symbol: SymbolRecord, in typeSymbols: [SymbolRecord]) -> [SymbolRecord] {
        typeSymbols.filter { type in
            !isSameSymbol(type, symbol)
                && type.startLine <= symbol.startLine
                && symbol.endLine <= type.endLine
        }
        .sorted(by: symbolContainmentOrder)
    }

    private func deepestContext(containing reference: SymbolRecord.Reference) -> SymbolRecord? {
        symbols
            .filter { symbol in
                symbol.kind.isKotlinReferenceContext
                    && symbol.startLine <= reference.startLine
                    && reference.endLine <= symbol.endLine
            }
            .sorted {
                let lhsSpan = $0.endLine - $0.startLine
                let rhsSpan = $1.endLine - $1.startLine
                if lhsSpan == rhsSpan { return $0.qualifiedName.count > $1.qualifiedName.count }
                return lhsSpan < rhsSpan
            }
            .first
    }

    private func isSameSymbol(_ lhs: SymbolRecord, _ rhs: SymbolRecord) -> Bool {
        lhs.kind == rhs.kind
            && lhs.name == rhs.name
            && lhs.startLine == rhs.startLine
            && lhs.endLine == rhs.endLine
    }

    private func symbolContainmentOrder(_ lhs: SymbolRecord, _ rhs: SymbolRecord) -> Bool {
        if lhs.startLine == rhs.startLine {
            let lhsSpan = lhs.endLine - lhs.startLine
            let rhsSpan = rhs.endLine - rhs.startLine
            if lhsSpan == rhsSpan { return lhs.name < rhs.name }
            return lhsSpan > rhsSpan
        }
        return lhs.startLine < rhs.startLine
    }

    private func classKind(for declaration: String) -> SymbolRecord.Kind {
        if declaration.contains(#"interface "#) { return .interface }
        if declaration.contains(#"enum class "#) { return .enum }
        if declaration.contains(#"data class "#) { return .dataClass }
        if declaration.contains(#"sealed class "#) { return .sealedClass }
        if declaration.contains(#"value class "#) || declaration.contains("@JvmInline") { return .valueClass }
        return .class
    }

    private func isSyntheticClassHeader(_ header: String) -> Bool {
        header.range(of: #"\b(?:enum\s+class|data\s+class|sealed\s+class|value\s+class|class|interface)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) != nil
    }

    private func isSyntheticObjectHeader(_ header: String) -> Bool {
        header.range(of: #"\b(?:companion\s+object|object)(?:\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*))?\b"#, options: .regularExpression) != nil
    }

    private func isTestFunction(name: String, declaration: String) -> Bool {
        let annotations = ["@Test", "@ParameterizedTest", "@RepeatedTest"]
        if annotations.contains(where: { declaration.contains($0) }) { return true }
        if typeStack.last?.hasSuffix("Test") == true || typeStack.last?.hasSuffix("Tests") == true {
            return cleanIdentifier(name).hasPrefix("test")
        }
        if filePath.contains("src/test/kotlin/") || filePath.contains("src/androidTest/kotlin/") || filePath.contains("src/iosTest/kotlin/") {
            return cleanIdentifier(name).hasPrefix("test") || name.hasPrefix("`")
        }
        return false
    }

    private func parseFunctionHeader(_ declaration: String) -> (name: String?, signature: String) {
        guard let funRange = declaration.range(of: #"\bfun\b"#, options: .regularExpression) else {
            return (nil, declaration)
        }

        let header = declarationHeader(from: String(declaration[funRange.lowerBound...]))
        guard let headerFunRange = header.range(of: #"\bfun\b"#, options: .regularExpression) else {
            return (nil, header)
        }

        var tail = String(header[headerFunRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.hasPrefix("<"), let end = matchingAngleEnd(in: tail) {
            tail = String(tail[tail.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let paren = tail.firstIndex(of: "(") else {
            return (nil, header)
        }

        let callable = String(tail[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = splitReceiverAndName(callable)
        guard let name = parts.name else {
            return (nil, header)
        }

        if let receiver = parts.receiver, !receiver.isEmpty {
            let rest = String(tail[paren...])
            return (name, "fun \(receiver).\(name)\(rest)".trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return (name, header)
    }

    private func splitReceiverAndName(_ callable: String) -> (receiver: String?, name: String?) {
        if callable.hasPrefix("`"), let end = callable.dropFirst().firstIndex(of: "`") {
            return (nil, String(callable[...end]))
        }

        let parts = callable.split(separator: ".", omittingEmptySubsequences: true)
        if parts.count > 1 {
            return (parts.dropLast().joined(separator: "."), String(parts.last!))
        }
        return (nil, callable.split(separator: " ").last.map(String.init))
    }

    private func matchingAngleEnd(in string: String) -> String.Index? {
        var depth = 0
        for index in string.indices {
            if string[index] == "<" { depth += 1 }
            if string[index] == ">" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private func declarationHeader(from declaration: String) -> String {
        var depth = 0
        var result = ""
        for scalar in declaration {
            if scalar == "(" || scalar == "<" || scalar == "[" { depth += 1 }
            if scalar == ")" || scalar == ">" || scalar == "]" { depth = max(0, depth - 1) }
            if depth == 0 && (scalar == "{" || scalar == "=" || scalar == "\n") { break }
            result.append(scalar)
        }
        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func declarationHeaderFromFirstMatch(_ pattern: String, in declaration: String) -> String {
        guard let range = declaration.range(of: pattern, options: .regularExpression) else {
            return declarationHeader(from: declaration)
        }
        return declarationHeader(from: String(declaration[range.lowerBound...]))
    }

    private func accessLevel(in declaration: String) -> String? {
        firstMatch(#"\b(public|internal|protected|private)\b"#, in: declaration, group: 1)
    }

    private func extractKDoc(before line: Int) -> String? {
        var index = max(0, line - 2)
        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            if index == 0 { return nil }
            index -= 1
        }

        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("@") {
            if index == 0 { return nil }
            index -= 1
        }

        guard index >= 0, lines[index].contains("*/") else { return nil }
        var collected: [String] = []
        while index >= 0 {
            collected.insert(lines[index], at: 0)
            if lines[index].contains("/**") { break }
            if index == 0 { break }
            index -= 1
        }

        let cleaned = collected
            .joined(separator: "\n")
            .replacingOccurrences(of: "/**", with: "")
            .replacingOccurrences(of: "*/", with: "")
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"^\s*\*\s?"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }

    private func nodeKind(_ node: TSNode) -> String {
        String(cString: ts_node_type(node))
    }

    private func text(for node: TSNode) -> String {
        let start = Int(ts_node_start_byte(node))
        let end = Int(ts_node_end_byte(node))
        guard start <= end, end <= content.utf8.count else { return "" }

        let utf8 = content.utf8
        guard
            let startIndex = String.Index(utf8.index(utf8.startIndex, offsetBy: start), within: content),
            let endIndex = String.Index(utf8.index(utf8.startIndex, offsetBy: end), within: content)
        else {
            return ""
        }

        return String(content[startIndex..<endIndex])
    }

    private func startLine(of node: TSNode) -> Int {
        Int(ts_node_start_point(node).row) + 1
    }

    private func endLine(of node: TSNode) -> Int {
        Int(ts_node_end_point(node).row) + 1
    }

    private func identifiers(in source: String) -> [String] {
        let pattern = #"`[^`]+`|[A-Za-z_][A-Za-z0-9_]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            return cleanIdentifier(String(source[range]))
        }
    }

    private func cleanIdentifier(_ identifier: String) -> String {
        var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("`"), value.hasSuffix("`"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func firstMatch(_ pattern: String, in source: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range), match.numberOfRanges > group else { return nil }
        guard let matchRange = Range(match.range(at: group), in: source) else { return nil }
        return String(source[matchRange])
    }
}

private extension SymbolRecord.Kind {
    var isKotlinTypeContainer: Bool {
        switch self {
        case .class, .interface, .enum, .object, .companion, .dataClass, .sealedClass, .valueClass:
            return true
        default:
            return false
        }
    }

    var isKotlinReferenceContext: Bool {
        switch self {
        case .function, .method, .test, .constructor:
            return true
        default:
            return isKotlinTypeContainer
        }
    }
}
