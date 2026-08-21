import Foundation
import CodeContextKitCore

/// Policy for what enters the Wax vector store.
///
/// Indexing every tiny method/property as its own MiniLM document collapses
/// natural-language recall once the corpus reaches a few thousand near-duplicate
/// stubs. Prefer types, documented symbols, and bodies with enough signal.
public enum SemanticIndexPolicy: Sendable {
    /// Minimum non-whitespace characters in the composed Wax document.
    public static let minimumDocumentLength = 80

    /// Type-level kinds always worth embedding (architectural anchors).
    public static let typeKinds: Set<SymbolRecord.Kind> = [
        .struct, .class, .actor, .enum, .protocol, .interface,
        .extension, .object, .companion, .dataClass, .sealedClass, .valueClass
    ]

    /// Whether this symbol should be written to Wax for semantic search.
    public static func shouldIndex(_ symbol: SymbolRecord, body: String) -> Bool {
        if symbol.kind == .file {
            // Whole-file fallbacks are too large/noisy for MiniLM (512-token cap).
            return false
        }

        let hasDocs = !(symbol.docComment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if typeKinds.contains(symbol.kind) { return true }
        if hasDocs { return true }

        // Undocumented members need a real body — skip empty stubs like `func f() {}`.
        let meaningfulBody = meaningfulContentLength(body: body, signature: symbol.signature)
        return meaningfulBody >= minimumDocumentLength
    }

    /// Composed text stored in Wax (and used for length / dedupe checks).
    public static func documentText(for symbol: SymbolRecord, body: String) -> String {
        var parts: [String] = [
            "\(symbol.kind) \(symbol.qualifiedName)",
            symbol.signature
        ]
        if let doc = symbol.docComment?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty {
            parts.append(doc)
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty, trimmedBody != symbol.signature {
            parts.append(trimmedBody)
        }
        return parts.joined(separator: "\n")
    }

    /// Identifier-shaped tokens embedded in prose or queries (CamelCase, snake_case).
    ///
    /// Used by pack for lexical SQLite hits. Vector fill is gated separately by
    /// `queryLooksIdentifierHeavy` so one CamelCase name in prose does not skip neighbors.
    public static func identifierTokens(in text: String) -> [String] {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "_")
        let tokens = text
            .components(separatedBy: separators)
            .filter { $0.count >= 2 }

        var seen = Set<String>()
        var out: [String] = []
        for token in tokens {
            guard isIdentifierLike(token) else { continue }
            if seen.insert(token).inserted {
                out.append(token)
            }
        }
        return out
    }

    /// True when the query is predominantly identifier-shaped, not merely containing one.
    ///
    /// Lexical: `AuthManager`, `AuthManager.refreshToken`, `pack_savings_ledger`.
    /// Vector: prose that mentions a type (`how does AuthManager handle …`) — one
    /// CamelCase token among many English words must not steal the meaning path.
    public static func queryLooksIdentifierHeavy(_ query: String) -> Bool {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "_")
        let tokens = query
            .components(separatedBy: separators)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return false }

        let identifierLike = tokens.filter(isIdentifierLike).count
        guard identifierLike >= 1 else { return false }
        // ≥ half the tokens look like identifiers (not "one name buried in prose").
        return identifierLike * 2 >= tokens.count
    }

    /// True when packing should stop after lexical primaries: no vector fill,
    /// associated skeletons, or repo map. Identifier-heavy tasks only
    /// (`AuthManager`, `AuthManager.refreshToken`). Two CamelCase names in
    /// prose still get neighbors and a map.
    public static func shouldSkipPackFiller(task: String) -> Bool {
        queryLooksIdentifierHeavy(task)
    }

    private static func isIdentifierLike(_ token: String) -> Bool {
        if token.contains("_") { return true }
        let letters = Array(token.filter(\.isLetter))
        guard letters.count >= 3 else { return false }
        let hasLower = letters.contains(where: \.isLowercase)
        // Internal capital distinguishes CamelCase/PascalCase from Titlecase English.
        let restHasUpper = letters.dropFirst().contains(where: \.isUppercase)
        return hasLower && restHasUpper
    }

    private static func meaningfulContentLength(body: String, signature: String) -> Int {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == signature {
            return 0
        }
        // Strip braces/punctuation-heavy stub residue so `func f() {}` does not pass.
        let stripped = trimmed
            .replacingOccurrences(of: signature, with: "")
            .filter { !$0.isWhitespace && $0 != "{" && $0 != "}" && $0 != "(" && $0 != ")" }
        return stripped.count
    }
}

/// Exclusive search routing shared by `cckit search` and the visualizer.
///
/// Identifier-shaped queries hit SQLite name/path match, not MiniLM.
/// `semantic:` only opts CLI into meaning search after the prefix is stripped.
public enum SearchRoute: Sendable, Equatable {
    case vector(String)
    case lexical(String, includeGrep: Bool, allowVectorFallback: Bool)

    /// CLI: unprefixed queries stay lexical + grep; `semantic:` then identifier vs vector.
    public static func resolveCLI(_ query: String) -> SearchRoute {
        if let inner = semanticInner(query) {
            return exclusive(inner, includeGrep: false)
        }
        return .lexical(query, includeGrep: true, allowVectorFallback: false)
    }

    /// Visualizer: no grep. Unprefixed prose still goes to Wax.
    public static func resolveVisualizer(_ query: String) -> SearchRoute {
        exclusive(strippedQuery(query), includeGrep: false)
    }

    public static func strippedQuery(_ query: String) -> String {
        semanticInner(query) ?? query
    }

    public static func isMultiWord(_ text: String) -> Bool {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count >= 2
    }

    private static func semanticInner(_ query: String) -> String? {
        guard query.hasPrefix("semantic:") else { return nil }
        return String(query.dropFirst(9)).trimmingCharacters(in: .whitespaces)
    }

    private static func exclusive(_ inner: String, includeGrep: Bool) -> SearchRoute {
        if SemanticIndexPolicy.queryLooksIdentifierHeavy(inner) {
            return .lexical(inner, includeGrep: includeGrep, allowVectorFallback: isMultiWord(inner))
        }
        return .vector(inner)
    }
}
