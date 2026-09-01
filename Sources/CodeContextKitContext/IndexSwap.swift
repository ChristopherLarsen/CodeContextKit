import Foundation

/// Snapshot-rebuild swap: staged builds go to `.cckit/staging/` and are moved
/// into place atomically once complete, so the live index never spends an
/// 18-minute rebuild in a partially-updated state (and `--clean` no longer
/// deletes the only index up front).
///
/// macOS APFS supports `renamex_np(RENAME_SWAP)` — an atomic exchange of two
/// paths. Readers (the MCP shim spawns a fresh CLI per call) observe either
/// the old or the new file; no inode is deleted out from under an open handle.
public enum IndexSwap {

    public enum SwapError: LocalizedError, Equatable {
        case stagedBuildMissing(path: String)

        public var errorDescription: String? {
            switch self {
            case .stagedBuildMissing(let path):
                return "Staged rebuild finished without a database at \(path); live index left untouched."
            }
        }
    }

    /// Atomically exchange `stagingPath` with `livePath` via RENAME_SWAP.
    /// Returns true when the exchange primitive was used; false when a
    /// fallback move dance ran (filesystem without RENAME_SWAP, or no live
    /// file yet). The fallback retires the live file into `retired-<uuid>/`
    /// beside the target and only deletes it after the move completes.
    @discardableResult
    public static func atomicSwap(_ stagingPath: String, with livePath: String) throws -> Bool {
        let swapped: Bool = stagingPath.withCString { from in
            livePath.withCString { to in
                renamex_np(from, to, UInt32(RENAME_SWAP)) == 0
            }
        }
        if swapped { return true }
        // Fallback (exotic mounts): retire-then-move. Crash between the two
        // moves loses the previous index, which a rebuild regenerates.
        let fm = FileManager.default
        let parent = (livePath as NSString).deletingLastPathComponent
        let retiredDir = (parent as NSString).appendingPathComponent("retired-\(UUID().uuidString)")
        try fm.createDirectory(atPath: retiredDir, withIntermediateDirectories: true)
        let retiredPath = (retiredDir as NSString)
            .appendingPathComponent((livePath as NSString).lastPathComponent)
        if fm.fileExists(atPath: livePath) {
            try fm.moveItem(atPath: livePath, toPath: retiredPath)
        }
        try fm.moveItem(atPath: stagingPath, toPath: livePath)
        return false
    }

    /// Swap a staged build (`index.sqlite` [+ `repo.wax`]) into the live index
    /// directory. The db is swapped first: it is the primary locator, and an
    /// arena lagging one swap is the same bounded-stale window delta runs
    /// already tolerate. Retired-db WAL sidecars are dropped — they belong to
    /// the discarded database and must never be replayed onto the new one.
    public static func swapBuildIntoPlace(
        cckitDir: String,
        stagingDir: String,
        dbPath: String,
        waxPath: String,
        includeWax: Bool
    ) throws {
        let fm = FileManager.default
        let stagingDb = "\(stagingDir)/index.sqlite"
        guard fm.fileExists(atPath: stagingDb) else {
            throw SwapError.stagedBuildMissing(path: stagingDb)
        }
        _ = try atomicSwap(stagingDb, with: dbPath)
        for suffix in ["-wal", "-shm"] {
            let sidecar = dbPath + suffix
            if fm.fileExists(atPath: sidecar) {
                try? fm.removeItem(atPath: sidecar)
            }
        }
        if includeWax {
            let stagingWax = "\(stagingDir)/repo.wax"
            if fm.fileExists(atPath: stagingWax) {
                _ = try atomicSwap(stagingWax, with: waxPath)
            }
        }
        // Staging now holds the retired files; remove it, plus any
        // `retired-*` dirs a crashed fallback left behind.
        try? fm.removeItem(atPath: stagingDir)
        if let entries = try? fm.contentsOfDirectory(atPath: cckitDir) {
            for entry in entries where entry.hasPrefix("retired-") {
                try? fm.removeItem(atPath: (cckitDir as NSString).appendingPathComponent(entry))
            }
        }
    }
}
