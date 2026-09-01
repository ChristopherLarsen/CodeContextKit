import Foundation
import CodeContextKitCore

/// Ripgrep whole-repo baseline for locator calls, so `find-symbol` /
/// `find-references` rows in the ledger become auditable.
///
/// The two most-used tools in the product previously logged `baselineTokens`
/// as 0 — indistinguishable from measured zero savings — so scoring them
/// required hand-running grep outside the tool. Measured on the reference
/// repo, the baseline is bimodal: common type names cost rg ~17–147× more
/// bytes than cckit, rare distinctive names land near ~1×. Recording it lets
/// the ledger surface that routing insight instead of hiding it.
///
/// Sentinel: `-1` means unmeasured (rg missing or the spawn failed). `0` is a
/// real measured zero and stays meaningful.
public enum LexicalBaseline {
    public static let unmeasured = -1

    /// rg candidates in probe order: Homebrew arm/intel prefixes first, then
    /// PATH resolution by the shell.
    static func rgCandidates() -> [String] {
        [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
        ]
    }

    /// Token estimate of what `rg -F "<pattern>"` returns repo-wide, excluding
    /// `.cckit/` (the ledger's own stored prompts would otherwise count —
    /// every recorded command embeds the caller's search terms).
    public static func tokens(for pattern: String, repoRoot: String = ".") -> Int {
        let output = searchOutput(pattern: pattern, repoRoot: repoRoot)
        guard let output else { return unmeasured }
        return TokenEstimator.shared.estimate(output)
    }

    static func searchOutput(pattern: String, repoRoot: String) -> String? {
        guard !pattern.isEmpty else { return nil }
        let candidates = rgCandidates()
        let executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else {
            // Fall back to PATH lookup.
            return run(executable: "/bin/sh",
                       arguments: ["-c", "command -v rg >/dev/null 2>&1 && exec rg --fixed-strings --no-heading --glob '!.cckit/**' \"$1\" .", "rg", pattern],
                       cwd: repoRoot)
        }
        return run(executable: executable,
                   arguments: ["--fixed-strings", "--no-heading", "--glob", "!.cckit/**", pattern, "."],
                   cwd: repoRoot)
    }

    /// `arguments` excludes the executable: Foundation prepends argv[0] from
    /// executableURL, so including it shifts every real argument by one
    /// (the pattern silently became a path).
    private static func run(executable: String, arguments: [String], cwd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        proc.standardOutput = out
        let err = Pipe()
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            FileHandle.standardError.write(Data("[LexicalBaseline] spawn failed: \(error)\n".utf8))
            return nil
        }
        // Drain to EOF before waiting — the MapBaseline pipe-buffer deadlock
        // rule. rg on a large repo can exceed 64 KB easily.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 || proc.terminationStatus == 1 else {
            // 0 = matches, 1 = no matches (a real measured zero), 2 = error.
            FileHandle.standardError.write(Data("[LexicalBaseline] rg exited \(proc.terminationStatus): \(String(decoding: errData, as: UTF8.self))\n".utf8))
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
