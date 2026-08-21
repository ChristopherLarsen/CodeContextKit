import Foundation
import CodeContextKitCore
import CodeContextKitStorage
import CodeContextKitSwiftIndex

public protocol RepoMapProgressDelegate: Sendable {
    func repoMapDidProgress(completed: Int, total: Int, currentFile: String)
}

/// Constructs a high-level architectural overview of the repository within a token budget.
///
/// Ranking is local (focus, kind, visibility) — no CoreML / ContextCore embeddings.
/// Agents call `map` as a subprocess; embedding every symbol hung that path for minutes.
public final class RepoMapBuilder {
    private let db: Database
    private let counter: @Sendable (String) async -> Int

    private static let importantKinds: Set<SymbolRecord.Kind> = [
        .class, .struct, .protocol, .actor, .enum, .interface, .case
    ]

    public init(db: Database, counter: @escaping @Sendable (String) async -> Int) {
        self.db = db
        self.counter = counter
    }

    public func buildMap(
        budget: Int,
        focusTerms: String? = nil,
        changedPaths: Set<String>? = nil,
        delegate: RepoMapProgressDelegate? = nil,
        verbose: Bool = false
    ) async throws -> String {
        var stderrStream = StderrOutputStream()
        let totalStartTime = Date()

        let dbStart = Date()
        var symbols = try db.getSymbolsForRepoMap()
        if let changedPaths, !changedPaths.isEmpty {
            symbols = symbols.filter { changedPaths.contains($0.filePath) }
        }
        let dbDuration = Date().timeIntervalSince(dbStart)
        if verbose {
            print(
                "[VERBOSE] DB: Fetched \(symbols.count) symbols in \(String(format: "%.3f", dbDuration))s",
                to: &stderrStream
            )
        }

        let rankStart = Date()
        var uniqueItems: [(content: String, score: Int)] = []
        var seenContents = Set<String>()
        uniqueItems.reserveCapacity(min(symbols.count, 4096))

        for (index, symbol) in symbols.enumerated() {
            if index % 100 == 0 {
                delegate?.repoMapDidProgress(
                    completed: index,
                    total: symbols.count,
                    currentFile: symbol.filePath
                )
            }

            let fileName = (symbol.filePath as NSString).lastPathComponent
            let fileBase = (fileName as NSString).deletingPathExtension
            let isTestFile = fileBase.lowercased().contains("test")
            let matchesFocus = Self.matchesFocus(symbol, terms: focusTerms)

            if !matchesFocus {
                if isTestFile { continue }
                if focusTerms != nil {
                    if !Self.importantKinds.contains(symbol.kind) { continue }
                } else {
                    let isLikelyPublic = symbol.accessLevel == "public"
                        || symbol.accessLevel == "open"
                        || symbol.accessLevel == nil
                    if !Self.importantKinds.contains(symbol.kind)
                        && !isLikelyPublic
                        && !symbol.name.hasPrefix("test")
                    {
                        continue
                    }
                }
            }

            let content = Self.skeleton(symbol: symbol, fileName: fileName, fileBase: fileBase)
            let score = Self.rank(
                symbol: symbol,
                fileBase: fileBase,
                matchesFocus: matchesFocus
            )

            if seenContents.insert(content).inserted {
                uniqueItems.append((content: content, score: score))
            } else if let idx = uniqueItems.firstIndex(where: { $0.content == content }) {
                uniqueItems[idx].score = max(uniqueItems[idx].score, score)
            }
        }

        uniqueItems.sort { $0.score > $1.score }
        let rankDuration = Date().timeIntervalSince(rankStart)
        if verbose {
            print(
                "[VERBOSE] Rank: Scored \(uniqueItems.count) unique skeletons in \(String(format: "%.3f", rankDuration))s",
                to: &stderrStream
            )
        }

        let joinStart = Date()
        let map = await RepoMapAssembler.assemble(
            chunks: uniqueItems.map(\.content),
            budget: budget,
            counter: counter
        )
        if verbose {
            let joinDuration = Date().timeIntervalSince(joinStart)
            print(
                "[VERBOSE] Format: Joined map content in \(String(format: "%.3f", joinDuration))s",
                to: &stderrStream
            )
            let totalDuration = Date().timeIntervalSince(totalStartTime)
            print(
                "[VERBOSE] Total Map Time: \(String(format: "%.3f", totalDuration))s",
                to: &stderrStream
            )
        }

        return map
    }

    private static func matchesFocus(_ symbol: SymbolRecord, terms: String?) -> Bool {
        guard let terms, !terms.isEmpty else { return false }
        let name = symbol.name.lowercased()
        let doc = symbol.docComment?.lowercased() ?? ""
        return terms.lowercased().split(separator: " ").contains { term in
            name.contains(term) || doc.contains(term)
        }
    }

    private static func skeleton(symbol: SymbolRecord, fileName: String, fileBase: String) -> String {
        var content = ""
        if symbol.name.lowercased() == fileBase.lowercased() {
            content = "\(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
        } else {
            content = "\(fileName): \(symbol.signature) [L\(symbol.startLine)-L\(symbol.endLine)]"
        }
        if let doc = symbol.docComment, !doc.isEmpty {
            content = "/// \(doc.replacingOccurrences(of: "\n", with: "\n/// "))\n\(content)"
        }
        return content
    }

    private static func rank(symbol: SymbolRecord, fileBase: String, matchesFocus: Bool) -> Int {
        var score = 0
        if matchesFocus { score += 1_000_000 }
        switch symbol.kind {
        case .class, .actor, .protocol: score += 300
        case .struct, .enum, .interface: score += 250
        case .case: score += 40
        default: score += 10
        }
        if symbol.accessLevel == "public" || symbol.accessLevel == "open" {
            score += 50
        }
        if symbol.name.lowercased() == fileBase.lowercased() {
            score += 40
        }
        if let doc = symbol.docComment, !doc.isEmpty {
            score += 5
        }
        return score
    }
}

private struct StderrOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        fputs(string, stderr)
        fflush(stderr)
    }
}

/// Policy for CLI progress bars that must never contaminate captured stdout.
public enum InteractiveProgress: Sendable {
    /// Map progress: only when `--verbose` and stdout is a TTY.
    /// Piped/MCP invocations stay silent even with `--verbose`.
    public static func shouldEmit(verbose: Bool, stdoutIsTTY: Bool) -> Bool {
        verbose && stdoutIsTTY
    }

    /// Index progress: TTY only (no verbose flag on `index`).
    public static func shouldEmitTTYProgress(stdoutIsTTY: Bool) -> Bool {
        stdoutIsTTY
    }

    public static func rankingLine(completed: Int, total: Int, currentFile: String) -> String {
        let percent = total > 0 ? Int(Double(completed) / Double(total) * 100) : 0
        let leaf = currentFile.split(separator: "/").last.map(String.init) ?? currentFile
        return "\rRanking symbols: \(percent)% [\(completed)/\(total)] \(leaf)"
    }

    public static func write(_ text: String, to handle: FileHandle) {
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }
}

/// Git helpers for `map --changed` path filtering (not a savings baseline).
public enum MapBaseline {
    /// Paths that differ from `base` (same filter as `--changed` on the map).
    public static func changedPaths(repoRoot: String, base: String) -> Set<String> {
        Set(git(["diff", "--name-only", base], repoRoot: repoRoot) ?? [])
    }

    private static func git(_ args: [String], repoRoot: String) -> [String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoRoot] + args
        proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

/// Assembles a repository map and trims it with the injected tokenizer so the
/// delivered payload (including the header) never exceeds `budget`.
enum RepoMapAssembler {
    static func header(tokens: Int, budget: Int) -> String {
        "# Repository Map (Tokens: \(tokens)/\(budget))\n\n"
            + "SYSTEM: Ranked type and public-symbol skeletons (no bodies).\n\n"
    }

    static func join(_ chunks: [String]) -> String {
        chunks.joined(separator: "\n---\n")
    }

    static func assemble(
        chunks: [String],
        budget: Int,
        counter: @escaping @Sendable (String) async -> Int
    ) async -> String {
        let cap = max(1, budget)
        var selected = await prefixFitting(chunks: chunks, budget: cap, counter: counter)
        var n = await counter(header(tokens: 0, budget: cap) + join(selected))
        var steps = 0

        while true {
            steps += 1
            let candidate = header(tokens: n, budget: cap) + join(selected)
            let actual = await counter(candidate)
            if actual == n && actual <= cap {
                return candidate
            }
            if actual <= cap {
                n = actual
                if steps > 16 { return candidate }
                continue
            }
            if selected.isEmpty || steps > 16 {
                return candidate
            }
            selected.removeLast()
            n = await counter(header(tokens: 0, budget: cap) + join(selected))
        }
    }

    /// Largest prefix whose header(0)+body is within budget (binary search).
    private static func prefixFitting(
        chunks: [String],
        budget: Int,
        counter: @escaping @Sendable (String) async -> Int
    ) async -> [String] {
        if chunks.isEmpty { return [] }
        var lo = 0
        var hi = chunks.count
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let text = header(tokens: 0, budget: budget) + join(Array(chunks.prefix(mid)))
            let n = await counter(text)
            if n <= budget {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return Array(chunks.prefix(best))
    }
}
