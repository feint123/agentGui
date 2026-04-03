import Foundation

// MARK: - CompactionTrackingState

/// CompactionCoordinator 的只读状态快照。在 @MainActor 上下文中安全传递。
struct CompactionTrackingState: Equatable, Sendable {
    let consecutiveFailures: Int
    let hasCompacted: Bool
    let isCompacting: Bool

    /// 连续失败达到上限，停止重试。对应 Claude Code MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3。
    var isCircuitBreakerTripped: Bool { consecutiveFailures >= CompactionCoordinator.maxConsecutiveFailures }

    /// 当前是否可发起新的压缩。
    var canAttempt: Bool { !isCompacting && !isCircuitBreakerTripped }
}

// MARK: - CompactionCoordinator

/// per-session actor：管理 auto-compact 的熔断状态与并发互斥。
///
/// 对应 Claude Code autoCompact.ts `AutoCompactTrackingState` + 熔断逻辑。
///
/// 调用方式：
/// ```swift
/// guard await coordinator.beginCompaction() else { return }
/// do {
///     let summary = try await generateSummary(...)
///     messages = engine.buildCompactedMessages(...)
///     await coordinator.recordSuccess()
/// } catch {
///     await coordinator.recordFailure()
/// }
/// ```
actor CompactionCoordinator {

    // MARK: - Constants

    /// 连续失败上限。对应 Claude Code MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3。
    static let maxConsecutiveFailures: Int = 3

    // MARK: - State

    private(set) var consecutiveFailures: Int = 0
    private(set) var hasCompacted: Bool = false
    private(set) var isCompacting: Bool = false

    // MARK: - State Machine

    /// 尝试开始一次压缩。
    /// - Returns: `true` 表示成功取得锁，调用方应继续执行压缩；`false` 表示条件不满足（熔断或重入）。
    func beginCompaction() -> Bool {
        guard !isCompacting, consecutiveFailures < Self.maxConsecutiveFailures else { return false }
        isCompacting = true
        return true
    }

    /// 记录压缩成功：重置失败计数、释放锁、标记 hasCompacted。
    func recordSuccess() {
        consecutiveFailures = 0
        hasCompacted = true
        isCompacting = false
    }

    /// 记录压缩失败：增加失败计数、释放锁。
    func recordFailure() {
        consecutiveFailures += 1
        isCompacting = false
    }

    /// 返回当前只读快照（用于外部轮询、日志、测试）。
    var trackingState: CompactionTrackingState {
        CompactionTrackingState(
            consecutiveFailures: consecutiveFailures,
            hasCompacted: hasCompacted,
            isCompacting: isCompacting
        )
    }
}
