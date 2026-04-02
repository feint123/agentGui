import Testing
import Foundation
import SwiftData
@testable import agentGui

@MainActor
struct MemoryConsolidationScheduleGateTests {

    // MARK: - 时间门关闭

    @Test func timeTooSoonReturnsFalse() async throws {
        let ctx = try makeContext()
        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        // lastConsolidatedAt = now - 20h（不足 24h）
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 20 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(!result.shouldFire)
    }

    // MARK: - 时间门通过但会话数不足

    @Test func timePassedButTooFewSessions() async throws {
        let ctx = try makeContext()
        // 插入 3 个 sessions（需要 5 个）
        for i in 0..<3 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)   // 30 min 前
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(!result.shouldFire)
        #expect(result.sessionCount == 3)
    }

    // MARK: - 双门槛均通过

    @Test func bothGatesPassReturnsTrue() async throws {
        let ctx = try makeContext()
        for i in 0..<6 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(result.shouldFire)
        #expect(result.sessionCount == 6)
    }

    // MARK: - currentSession 被排除

    @Test func currentSessionExcluded() async throws {
        let ctx = try makeContext()
        for i in 0..<5 {
            let s = Session()
            s.sessionId = i == 4 ? "current" : "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 1,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 2 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        // 5 sessions 中 current 被排除，只剩 4 个 < minSessions=5
        #expect(!result.shouldFire)
        #expect(result.sessionCount == 4)
    }

    // MARK: - helper

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: config)
        return ModelContext(container)
    }
}
