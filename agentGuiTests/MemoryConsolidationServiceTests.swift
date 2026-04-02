import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - MemoryConsolidationCoordinatorTests

struct MemoryConsolidationCoordinatorTests {

    @Test func beginReturnsTrueWhenIdle() async {
        let c = MemoryConsolidationCoordinator()
        let result = await c.beginConsolidation()
        #expect(result)
    }

    @Test func beginReturnsFalseWhileRunning() async {
        let c = MemoryConsolidationCoordinator()
        _ = await c.beginConsolidation()
        let second = await c.beginConsolidation()
        #expect(!second)
    }

    @Test func canBeginAgainAfterFinish() async {
        let c = MemoryConsolidationCoordinator()
        _ = await c.beginConsolidation()
        await c.finishConsolidation()
        let again = await c.beginConsolidation()
        #expect(again)
    }
}

// MARK: - MemoryConsolidationServiceTests

@MainActor
struct MemoryConsolidationServiceTests {

    // MARK: - 时间门未通过 → 不启动 subagent

    @Test func doesNotFireWhenTimeTooSoon() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        var subagentCallCount = 0

        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 1 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - 会话数不足 → 不启动 subagent

    @Test func doesNotFireWhenTooFewSessions() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        for i in 0..<3 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "S\(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()
        var subagentCallCount = 0

        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - 双门槛通过 → 启动 subagent，传入 sessionIds

    @Test func firesAndPassesSessionIdsWhenBothGatesPass() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        let expectedIds = (0..<6).map { "s\($0)" }
        for id in expectedIds {
            let s = Session()
            s.sessionId = id
            s.title = id
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()

        var receivedSessionIds: [String] = []
        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, sessionIds in receivedSessionIds = sessionIds },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(receivedSessionIds.count == 6)
        #expect(Set(receivedSessionIds) == Set(expectedIds))
    }

    // MARK: - Coordinator 防重入

    @Test func doesNotFireWhenAlreadyRunning() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        for i in 0..<6 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "S\(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()

        let coordinator = MemoryConsolidationCoordinator()
        // 预先占用 coordinator
        _ = await coordinator.beginConsolidation()

        var subagentCallCount = 0
        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: coordinator
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - helpers

    private func tmpMemDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m06-svc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: config)
        return ModelContext(container)
    }
}
