import Foundation
import SwiftData

/// 双门槛检查器：决定是否应该触发记忆整合。
///
/// 门槛顺序（由廉价到昂贵）：
///  1. **时间门**：距 `lastConsolidatedAt` ≥ minHours
///  2. **会话数门**：SwiftData 中 `updatedAt > lastConsolidatedAt` 且非 currentSession 的 Session 计数 ≥ minSessions
struct MemoryConsolidationScheduleGate: Sendable {

    struct CheckResult: Sendable {
        let shouldFire: Bool
        let sessionCount: Int
        let hoursSince: Double
    }

    let minHours: Double
    let minSessions: Int
    let modelContext: ModelContext

    init(modelContext: ModelContext, minHours: Double = 24, minSessions: Int = 5) {
        self.modelContext = modelContext
        self.minHours = minHours
        self.minSessions = minSessions
    }

    /// 检查双门槛，返回结果（含调试信息）。
    @MainActor
    func shouldConsolidate(
        lastConsolidatedAtMs: Double,
        currentSessionId: String
    ) async -> CheckResult {
        let lastAt = Date(timeIntervalSince1970: lastConsolidatedAtMs / 1000)
        let hoursSince = Date.now.timeIntervalSince(lastAt) / 3600

        // --- 时间门 ---
        guard hoursSince >= minHours else {
            return CheckResult(shouldFire: false, sessionCount: 0, hoursSince: hoursSince)
        }

        // --- 会话数门（SwiftData fetch） ---
        let count = sessionCountSince(lastAt, excludingSessionId: currentSessionId)
        let shouldFire = count >= minSessions
        return CheckResult(shouldFire: shouldFire, sessionCount: count, hoursSince: hoursSince)
    }

    // MARK: - Private

    /// 统计 `updatedAt > since` 且 sessionId ≠ excluded 的 Session 数量。
    @MainActor
    private func sessionCountSince(_ since: Date, excludingSessionId excluded: String) -> Int {
        let sinceDate = since
        let excludedId = excluded
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { session in
                session.updatedAt > sinceDate && session.sessionId != excludedId
            }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}
