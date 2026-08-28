import Foundation
import Testing
@testable import CodeContextKitRetrieval

@Suite("Wax live-set residue sweep")
struct WaxResidueSweeperTests {
    @Test("removes candidates and promotion backups, including fresh backups")
    func removesAllResidue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-wax-residue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let candidate = directory.appendingPathComponent("repo-liveset-ABC.wax")
        let backup = directory.appendingPathComponent("repo.wax.pre-liveset-DEF")
        let arena = directory.appendingPathComponent("repo.wax")
        let unrelated = directory.appendingPathComponent("repo-liveset-ABC.txt")
        try Data(repeating: 1, count: 4_096).write(to: candidate)
        try Data(repeating: 2, count: 4_096).write(to: backup)
        try Data(repeating: 3, count: 128).write(to: arena)
        try Data(repeating: 4, count: 128).write(to: unrelated)

        let result = WaxResidueSweeper.sweep(cckitDirectory: directory.path)

        #expect(result.removedFiles == 2)
        #expect(result.reclaimedAllocatedBytes > 0)
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(FileManager.default.fileExists(atPath: arena.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("does not recursively delete a matching directory")
    func skipsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-wax-residue-dir-\(UUID().uuidString)", isDirectory: true)
        let matchingDirectory = directory.appendingPathComponent("repo-liveset-DIR.wax", isDirectory: true)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = WaxResidueSweeper.sweep(cckitDirectory: directory.path)

        #expect(result.removedFiles == 0)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: matchingDirectory.path))
    }

    @Test("stable arena lease rejects a second opener and releases cleanly")
    func stableLeaseExcludesOtherOpeners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-wax-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("repo.wax").path

        let first = try WaxStore.acquireLease(for: path)
        #expect(throws: WaxStore.StoreError.self) {
            _ = try WaxStore.acquireLease(for: path)
        }
        first.release()

        let second = try WaxStore.acquireLease(for: path)
        second.release()
    }

    @Test("restores a sole promotion backup before open")
    func restoresSolePromotionBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-wax-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arena = directory.appendingPathComponent("repo.wax")
        let backup = directory.appendingPathComponent("repo.wax.pre-liveset-ONLY")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: backup)

        try WaxStore.recoverSolePromotionBackupIfNeeded(at: arena.path)

        #expect(FileManager.default.contents(atPath: arena.path) == bytes)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("refuses ambiguous promotion backup recovery")
    func refusesAmbiguousPromotionBackups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-wax-recovery-many-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arena = directory.appendingPathComponent("repo.wax")
        let first = directory.appendingPathComponent("repo.wax.pre-liveset-A")
        let second = directory.appendingPathComponent("repo.wax.pre-liveset-B")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)

        #expect(throws: WaxStore.StoreError.self) {
            try WaxStore.recoverSolePromotionBackupIfNeeded(at: arena.path)
        }
        #expect(!FileManager.default.fileExists(atPath: arena.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
