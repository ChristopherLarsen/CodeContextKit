import Foundation

/// Git commit/branch stamped when the index was built (`.cckit/index-stamp.json`).
public struct IndexStamp: Codable, Sendable, Equatable {
    public var commit: String
    public var branch: String
    public var indexedAt: Date

    public init(commit: String, branch: String, indexedAt: Date = Date()) {
        self.commit = commit
        self.branch = branch
        self.indexedAt = indexedAt
    }

    public static let fileName = "index-stamp.json"

    public static func fileURL(cckitDir: String = ".cckit") -> URL {
        URL(fileURLWithPath: cckitDir, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func load(cckitDir: String = ".cckit") -> IndexStamp? {
        let url = fileURL(cckitDir: cckitDir)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(IndexStamp.self, from: data)
    }

    public func write(cckitDir: String = ".cckit") throws {
        let dir = URL(fileURLWithPath: cckitDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL(cckitDir: cckitDir), options: .atomic)
    }
}

/// Compares the index stamp to the current git HEAD.
public struct IndexFreshness: Sendable, Equatable {
    public var stale: Bool
    public var indexedCommit: String?
    public var indexedBranch: String?
    public var headCommit: String?
    public var headBranch: String?

    public init(
        stale: Bool,
        indexedCommit: String? = nil,
        indexedBranch: String? = nil,
        headCommit: String? = nil,
        headBranch: String? = nil
    ) {
        self.stale = stale
        self.indexedCommit = indexedCommit
        self.indexedBranch = indexedBranch
        self.headCommit = headCommit
        self.headBranch = headBranch
    }

    /// Snapshot current git HEAD (commit + branch) for `repoRoot`.
    public static func gitHead(repoRoot: String = ".") -> (commit: String, branch: String)? {
        let commit = gitOutput(["rev-parse", "HEAD"], cwd: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit, !commit.isEmpty, let branch, !branch.isEmpty else { return nil }
        return (commit, branch)
    }

    public static func captureStamp(repoRoot: String = ".") -> IndexStamp? {
        guard let head = gitHead(repoRoot: repoRoot) else { return nil }
        return IndexStamp(commit: head.commit, branch: head.branch)
    }

    /// Load stamp under `repoRoot/.cckit` and compare to HEAD.
    public static func check(repoRoot: String = ".") -> IndexFreshness {
        let cckit = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(".cckit")
            .path
        let stamp = IndexStamp.load(cckitDir: cckit)
        let head = gitHead(repoRoot: repoRoot)
        let stale: Bool
        if let stamp, let head {
            stale = stamp.commit != head.commit
        } else if stamp == nil, head != nil {
            // Indexed before stamping existed, or stamp missing after clean of stamp only.
            stale = true
        } else {
            stale = false
        }
        return IndexFreshness(
            stale: stale,
            indexedCommit: stamp?.commit,
            indexedBranch: stamp?.branch,
            headCommit: head?.commit,
            headBranch: head?.branch
        )
    }

    /// Compact envelope for locator/content tools: empty when fresh; minimal when stale.
    /// Absence of `stale` means the index is current.
    public var compactDictionary: [String: Any] {
        guard stale else { return [:] }
        var dict: [String: Any] = ["stale": true]
        if let indexedCommit {
            dict["indexedCommit"] = String(indexedCommit.prefix(8))
        }
        if let headCommit {
            dict["headCommit"] = String(headCommit.prefix(8))
        }
        if indexedBranch != headBranch {
            if let indexedBranch { dict["indexedBranch"] = indexedBranch }
            if let headBranch { dict["headBranch"] = headBranch }
        }
        return dict
    }

    /// Soft CLI note — staleness usually means line numbers in recently touched files may drift,
    /// not that the whole tool is untrustworthy.
    public var softWarning: String? {
        guard stale else { return nil }
        let headShort = headCommit.map { String($0.prefix(8)) } ?? "?"
        let indexedShort = indexedCommit.map { String($0.prefix(8)) } ?? "?"
        var lag = "HEAD \(headShort) vs indexed \(indexedShort)"
        if let headBranch, let indexedBranch, headBranch != indexedBranch {
            lag += " (\(headBranch) vs \(indexedBranch))"
        }
        return
            "Note: index lags \(lag). "
            + "Line numbers in recently changed files may be slightly off; "
            + "run `cckit index` (or let MCP auto-refresh) when exact lines matter."
    }

    private static func gitOutput(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            // Drain to EOF before waiting; the reverse order deadlocks once
            // output exceeds the ~64 KB pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
