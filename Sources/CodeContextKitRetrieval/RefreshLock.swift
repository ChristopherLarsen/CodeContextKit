import Foundation
import Darwin

/// Repo-wide single-writer lock for `.cckit/refresh.lock`.
///
/// One writer per arena regardless of trigger source (CLI, MCP shim, git
/// hooks, `cckit serve`'s dashboard reindex): contended callers DROP, they
/// never queue a second rebuild behind the first. Held for the lifetime of
/// the lease; released implicitly on process exit even on crash.
///
/// Hardened against the two ways a plain `flock` pair silently stops being
/// exclusive:
/// 1. The lock file is deleted and recreated while held (e.g. `git clean -x`,
///    manual `.cckit` pruning): the second writer would open and flock a NEW
///    inode and both would proceed. Every acquire therefore verifies that the
///    flocked inode still matches the path before reporting success.
/// 2. Pileups are undiagnosable: the holder stamps pid/argv/start into the
///    lock file so a later investigation can see who held (or last held) it.
public enum RefreshLock {
    /// An acquired exclusive lock. Release closes the fd, dropping the lock.
    public final class Lease: @unchecked Sendable {
        private let stateLock = NSLock()
        private var fd: Int32
        private let lockPath: String

        fileprivate init(fd: Int32, lockPath: String) {
            self.fd = fd
            self.lockPath = lockPath
        }

        public func release() {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }

        deinit {
            release()
        }
    }

    /// Acquire the lock without blocking. Returns nil when another writer
    /// holds it (or the lock file cannot be opened).
    public static func tryAcquire(lockPath: String) -> Lease? {
        for _ in 0..<3 {
            let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            // The file must still be the one we flocked: a concurrent
            // delete-and-recreate would leave us holding an orphaned inode.
            guard sameInode(fd: fd, path: lockPath) else {
                close(fd)
                continue
            }
            stampHolder(fd: fd, lockPath: lockPath)
            return Lease(fd: fd, lockPath: lockPath)
        }
        return nil
    }

    /// Non-blocking probe: true when some process holds the lock right now.
    /// Used to avoid spawning a child that would drop itself; racy by design.
    public static func isHeld(lockPath: String) -> Bool {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }

    private static func sameInode(fd: Int32, path: String) -> Bool {
        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0 else { return false }
        guard let pathStat = statOf(path) else { return false }
        return fdStat.st_dev == pathStat.st_dev && fdStat.st_ino == pathStat.st_ino
    }

    private static func statOf(_ path: String) -> stat? {
        var s = stat()
        guard stat(path, &s) == 0 else { return nil }
        return s
    }

    /// Overwrite the lock file with the current holder's identity. Best
    /// effort — never blocks or fails acquisition.
    private static func stampHolder(fd: Int32, lockPath: String) {
        let argv = CommandLine.arguments.joined(separator: " ")
        let payload: [String: Any] = [
            "pid": Int(getpid()),
            "command": argv,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        _ = lseek(fd, 0, SEEK_SET)
        _ = ftruncate(fd, 0)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return }
                remaining -= written
                pointer += written
            }
        }
    }
}
