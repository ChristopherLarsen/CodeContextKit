import Foundation
import CodeContextKitRetrieval

/// Seeds a linked git worktree's `.cckit` from the main checkout's index.
///
/// A cold semantic index of a large repo costs ~30 minutes, and `.cckit/` is
/// gitignored, so every fresh worktree starts empty. An agent's first locator
/// call then fails with "Index not found" and it falls back to grep for the
/// whole task. Index paths are repo-relative, so the main checkout's db and
/// arena are valid in any worktree of the same repo: clone them (APFS
/// clonefile, near-instant and space-shared) and let the normal incremental
/// run re-index only the files that differ.
///
/// Seeds only when the target has no index at all (no stamp, no db); a
/// partial or existing index is never replaced.
public enum WorktreeIndexSeed {
    public static let eventName = "WorktreeSeed"

    /// Durable state carried over. Never locks, liveset residue, breach
    /// markers, or ledgers (action_history, pack_savings) — those describe
    /// the source checkout, not this one.
    static let seededFiles = [
        "index.sqlite",
        "index.sqlite-wal",
        "index.sqlite-shm",
        "repo.wax",
        WaxEmbedderIdentity.sidecarFileName,
        "wax-compact-stamp.json",
        "index-stamp.json",
        "config.json",
        "lexical-only",
    ]

    public enum Outcome: Equatable, Sendable {
        case seeded(source: String, files: [String])
        case skipped(reason: String)

        public var payload: [String: Any] {
            switch self {
            case .seeded(let source, let files):
                return ["seeded": true, "source": source, "files": files]
            case .skipped(let reason):
                return ["seeded": false, "reason": reason]
            }
        }

        public var jsonLine: String {
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            return "\(WorktreeIndexSeed.eventName) " + (String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    /// True when `repoRoot` has never been indexed (no stamp and no db).
    public static func needsSeed(repoRoot: String, cckitDir: String = ".cckit") -> Bool {
        let dir = absolute(cckitDir, in: repoRoot)
        let fm = FileManager.default
        return !fm.fileExists(atPath: (dir as NSString).appendingPathComponent("index-stamp.json"))
            && !fm.fileExists(atPath: (dir as NSString).appendingPathComponent("index.sqlite"))
    }

    /// The main checkout of the repo containing `repoRoot`, when `repoRoot`
    /// is a linked worktree; nil for the main checkout or a non-git folder.
    public static func mainCheckout(of repoRoot: String) -> String? {
        guard let top = git(["rev-parse", "--show-toplevel"], cwd: repoRoot)?.trimmed,
              let list = git(["worktree", "list", "--porcelain"], cwd: repoRoot) else { return nil }
        // The first entry is always the main worktree.
        guard let first = list.split(separator: "\n").first(where: { $0.hasPrefix("worktree ") }) else {
            return nil
        }
        let main = String(first.dropFirst("worktree ".count))
        guard canonical(main) != canonical(top) else { return nil }
        return main
    }

    /// Clone the main checkout's index into `repoRoot/cckitDir` when the
    /// target is an unindexed linked worktree. The caller must hold the
    /// target's refresh lock. Waits up to `lockWait` for the source's
    /// refresh lock so a mid-swap db/arena pair is never cloned.
    public static func seedIfNeeded(
        repoRoot: String,
        cckitDir: String = ".cckit",
        lockWait: TimeInterval = 30
    ) -> Outcome {
        guard needsSeed(repoRoot: repoRoot, cckitDir: cckitDir) else {
            return .skipped(reason: "already_indexed")
        }
        guard let main = mainCheckout(of: repoRoot) else {
            return .skipped(reason: "not_linked_worktree")
        }
        let source = (main as NSString).appendingPathComponent(".cckit")
        let fm = FileManager.default
        func sourcePath(_ name: String) -> String { (source as NSString).appendingPathComponent(name) }

        guard fm.fileExists(atPath: sourcePath("index-stamp.json")),
              fm.fileExists(atPath: sourcePath("index.sqlite")) else {
            return .skipped(reason: "source_unindexed")
        }
        let lexicalOnly = fm.fileExists(atPath: sourcePath("lexical-only"))
        if !lexicalOnly {
            let stored = (try? String(contentsOfFile: sourcePath(WaxEmbedderIdentity.sidecarFileName), encoding: .utf8))?.trimmed
            guard stored == WaxEmbedderIdentity.current else {
                return .skipped(reason: "source_embedder_mismatch")
            }
            guard fm.fileExists(atPath: sourcePath("repo.wax")) else {
                return .skipped(reason: "source_missing_wax")
            }
        }

        guard let sourceLease = acquire(lockPath: sourcePath("refresh.lock"), wait: lockWait) else {
            return .skipped(reason: "source_locked")
        }
        defer { sourceLease.release() }

        let target = absolute(cckitDir, in: repoRoot)
        do {
            try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
            var copied: [String] = []
            // Copy under temporary names, then rename, so a crash mid-seed
            // never leaves a db without its arena under the real names.
            for name in seededFiles where fm.fileExists(atPath: sourcePath(name)) {
                let tmp = (target as NSString).appendingPathComponent(name + ".seed-tmp")
                try? fm.removeItem(atPath: tmp)
                try fm.copyItem(atPath: sourcePath(name), toPath: tmp)
                copied.append(name)
            }
            // index.sqlite last: needsSeed keys on it, so it lands only once
            // every companion file is in place.
            let ordered = copied.filter { $0 != "index.sqlite" } + (copied.contains("index.sqlite") ? ["index.sqlite"] : [])
            for name in ordered {
                let tmp = (target as NSString).appendingPathComponent(name + ".seed-tmp")
                let dest = (target as NSString).appendingPathComponent(name)
                if rename(tmp, dest) != 0 {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return .seeded(source: main, files: copied)
        } catch {
            for name in seededFiles {
                try? fm.removeItem(atPath: (target as NSString).appendingPathComponent(name + ".seed-tmp"))
            }
            return .skipped(reason: "copy_failed: \(error.localizedDescription)")
        }
    }

    private static func acquire(lockPath: String, wait: TimeInterval) -> RefreshLock.Lease? {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if let lease = RefreshLock.tryAcquire(lockPath: lockPath) { return lease }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func absolute(_ path: String, in root: String) -> String {
        path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func git(_ args: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
