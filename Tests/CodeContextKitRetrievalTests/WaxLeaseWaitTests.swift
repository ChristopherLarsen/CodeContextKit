import Foundation
import Testing
@testable import CodeContextKitRetrieval

@Suite("Wax writer lease wait")
struct WaxLeaseWaitTests {
    private func tempArena() throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cckit-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("repo.wax").path)
    }

    @Test("waits for a short-lived holder instead of failing")
    func waitsForHolder() throws {
        let (dir, path) = try tempArena()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = try WaxStore.acquireLease(for: path)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { holder.release() }

        let lease = try WaxStore.acquireLease(for: path, waitingUpTo: 5)
        lease.release()
    }

    @Test("fails once the wait expires")
    func failsAfterWait() throws {
        let (dir, path) = try tempArena()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holder = try WaxStore.acquireLease(for: path)
        defer { holder.release() }

        #expect(throws: WaxStore.StoreError.self) {
            _ = try WaxStore.acquireLease(for: path, waitingUpTo: 0.3)
        }
    }

    @Test("wait is env-tunable with a 120 s default")
    func waitFromEnvironment() {
        #expect(WaxStore.writerLeaseWait(environment: [:]) == 120)
        #expect(WaxStore.writerLeaseWait(environment: ["CCKIT_WAX_LEASE_WAIT_SECONDS": "5"]) == 5)
        #expect(WaxStore.writerLeaseWait(environment: ["CCKIT_WAX_LEASE_WAIT_SECONDS": "bad"]) == 120)
    }
}
