import Foundation
import CodeContextKitCore
import CodeContextKitStorage

/// Reads a symbol body from current disk content. Indexed line ranges are used
/// only when the file hash still matches; otherwise the file is parsed locally
/// and the symbol is rematched (semantic re-embedding stays asynchronous).
public enum FreshSymbolResolver: Sendable {
    public struct Slice: Sendable {
        public var symbol: SymbolRecord
        public var body: String
        public var locatorOnly: Bool
        public var rematched: Bool
    }

    public static func slice(
        symbol: SymbolRecord,
        content: String,
        indexedHash: String?,
        currentHash: String
    ) -> Slice {
        if !ImplementationSpanPolicy.hasReliableImplementationSpan(filePath: symbol.filePath) {
            return Slice(
                symbol: symbol,
                body: declarationLine(content: content, startLine: symbol.startLine),
                locatorOnly: true,
                rematched: false
            )
        }

        let hashMatches = indexedHash != nil && indexedHash == currentHash
        if hashMatches {
            return Slice(
                symbol: symbol,
                body: LineRangeBodyExtractor.body(for: symbol, content: content),
                locatorOnly: false,
                rematched: false
            )
        }

        let splitter = SplitterRouter().splitter(for: symbol.filePath)
        let (fresh, _) = splitter.extractSymbols(content: content, filePath: symbol.filePath)
        if let matched = match(symbol, in: fresh) {
            return Slice(
                symbol: matched,
                body: LineRangeBodyExtractor.body(for: matched, content: content),
                locatorOnly: false,
                rematched: true
            )
        }

        return Slice(symbol: symbol, body: "", locatorOnly: false, rematched: true)
    }

    public static func match(_ wanted: SymbolRecord, in fresh: [SymbolRecord]) -> SymbolRecord? {
        let exact = fresh.filter {
            $0.qualifiedName == wanted.qualifiedName && $0.signature == wanted.signature
        }
        if exact.count == 1 { return exact[0] }
        if let sameKind = exact.first(where: { $0.kind == wanted.kind }) {
            return sameKind
        }
        if let byName = fresh.first(where: {
            $0.qualifiedName == wanted.qualifiedName && $0.kind == wanted.kind
        }) {
            return byName
        }
        if let byLeaf = fresh.first(where: {
            $0.name == wanted.name && $0.kind == wanted.kind
        }) {
            return byLeaf
        }
        return fresh.first(where: { $0.name == wanted.name })
    }

    public static func extensions(
        of typeName: String,
        in symbols: [SymbolRecord]
    ) -> [SymbolRecord] {
        symbols.filter { $0.kind == .extension && ($0.name == typeName || $0.qualifiedName == typeName) }
    }

    private static func declarationLine(content: String, startLine: Int) -> String {
        let lines = content.components(separatedBy: .newlines)
        let idx = max(0, startLine - 1)
        guard idx < lines.count else { return "" }
        return lines[idx]
    }
}

/// Compares indexed `fileRecord` hashes against current disk contents.
public enum IndexedContentFreshness: Sendable {
    public static func mismatchedPaths(db: Database, repoRoot: String) throws -> [String] {
        let files = try db.getAllFiles()
        let hasher = FileHasher()
        var mismatched: [String] = []
        for record in files {
            let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(record.path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else {
                mismatched.append(record.path)
                continue
            }
            if hasher.hash(content: content) != record.sha256 {
                mismatched.append(record.path)
            }
        }
        return mismatched
    }

    public static func isContentStale(db: Database, repoRoot: String) -> Bool {
        (try? mismatchedPaths(db: db, repoRoot: repoRoot).isEmpty) == false
    }
}
