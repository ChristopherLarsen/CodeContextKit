import Foundation

/// Removes unpromoted Wax live-set rewrite artifacts after the owning store has
/// closed successfully, or immediately before the store is deliberately rebuilt.
public enum WaxResidueSweeper {
    public struct Result: Sendable, Equatable {
        public let removedFiles: Int
        public let reclaimedAllocatedBytes: Int
        public let failures: [String]

        public init(removedFiles: Int, reclaimedAllocatedBytes: Int, failures: [String]) {
            self.removedFiles = removedFiles
            self.reclaimedAllocatedBytes = reclaimedAllocatedBytes
            self.failures = failures
        }
    }

    /// Sweep candidates and promotion backups beside `repo.wax`.
    ///
    /// Callers must hold the repo refresh lock and must invoke this only after a
    /// successful Wax close or while rebuilding the arena from scratch. Under
    /// either precondition no residue file is the authoritative arena.
    public static func sweep(cckitDirectory: String) -> Result {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: cckitDirectory) else {
            return Result(removedFiles: 0, reclaimedAllocatedBytes: 0, failures: [])
        }

        var removedFiles = 0
        var reclaimedAllocatedBytes = 0
        var failures: [String] = []

        for entry in entries.sorted() where isResidueName(entry) {
            let url = URL(fileURLWithPath: cckitDirectory, isDirectory: true)
                .appendingPathComponent(entry, isDirectory: false)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let allocatedBytes = WaxStore.waxFileAllocatedBytes(at: url.path)
            do {
                try fileManager.removeItem(at: url)
                removedFiles += 1
                reclaimedAllocatedBytes += allocatedBytes
            } catch {
                failures.append("\(entry): \(error.localizedDescription)")
            }
        }

        return Result(
            removedFiles: removedFiles,
            reclaimedAllocatedBytes: reclaimedAllocatedBytes,
            failures: failures
        )
    }

    private static func isResidueName(_ name: String) -> Bool {
        let isCandidate = name.hasPrefix("repo-liveset-") && name.hasSuffix(".wax")
        let isBackup = name.hasPrefix("repo.wax.pre-liveset-")
        return isCandidate || isBackup
    }
}
