import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationLockManagerTests {

    // MARK: - readLastConsolidatedAt

    @Test func returnsZeroWhenLockFileAbsent() async throws {
        let dir = tmpDir()
        let manager = MemoryConsolidationLockManager(memoryDir: dir)
        let t = try await manager.readLastConsolidatedAt()
        #expect(t == 0)
    }

    @Test func returnsFileMtimeAfterAcquire() async throws {
        let dir = tmpDir()
        let mgr = MemoryConsolidationLockManager(memoryDir: dir)
        let before = Date.now.timeIntervalSince1970 * 1000
        let prior = try await mgr.tryAcquire()
        let after = Date.now.timeIntervalSince1970 * 1000
        let last = try await mgr.readLastConsolidatedAt()
        #expect(prior != nil)
        #expect(last >= before)
        #expect(last <= after + 1000)   // 1s 容差
    }

    // MARK: - tryAcquire 竞争

    @Test func acquireReturnsPriorMtime() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        let prior1 = try await m.tryAcquire()   // 第一次：no prior file → prior = 0
        #expect(prior1 == 0)

        let prior2 = try await m.tryAcquire()   // 第二次：持有者是自己 → 允许重入（视为 nil 竞争失败）
        #expect(prior2 == nil)
    }

    // MARK: - rollback

    @Test func rollbackToZeroDeletesLockFile() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        _ = try await m.tryAcquire()
        try await m.rollback(to: 0)
        let t = try await MemoryConsolidationLockManager(memoryDir: dir).readLastConsolidatedAt()
        #expect(t == 0)
    }

    @Test func rollbackToNonZeroRestoresMtime() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        _ = try await m.tryAcquire()
        let target = 1_700_000_000_000.0
        try await m.rollback(to: target)
        let restored = try await m.readLastConsolidatedAt()
        #expect(abs(restored - target) < 1000)   // 1s 容差（utimes 精度）
    }

    // MARK: - commitConsolidation

    @Test func commitUpdatesLastConsolidatedAt() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        let before = Date.now.timeIntervalSince1970 * 1000
        try await m.commitConsolidation()
        let after = Date.now.timeIntervalSince1970 * 1000
        let t = try await m.readLastConsolidatedAt()
        #expect(t >= before)
        #expect(t <= after + 1000)
    }

    // MARK: - helpers

    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m06-lock-\(UUID().uuidString)", isDirectory: true)
    }
}
