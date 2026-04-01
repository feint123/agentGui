import Foundation

// MARK: - Constants
// 直接对应 Claude Code autoCompact.ts 中的值

private let kMaxOutputTokensReserved = 20_000   // MAX_OUTPUT_TOKENS_FOR_SUMMARY
private let kAutocompactBufferTokens  = 13_000   // AUTOCOMPACT_BUFFER_TOKENS
private let kWarningBufferTokens      = 20_000   // WARNING_THRESHOLD_BUFFER_TOKENS

// MARK: - BudgetLevel

/// 上下文预算的四级状态，对应 Claude Code calculateTokenWarningState() 的输出。
enum BudgetLevel: String, Equatable, Sendable {
    /// 使用量低于 warning 阈值，正常运行。
    case normal
    /// 使用量超过 warning 阈值，UI 可显示黄色警告。
    case warning
    /// 使用量超过 autoCompact 阈值，应触发自动压缩。
    case critical
    /// 使用量极高，超过 blocking 阈值，可能需要阻断继续运行。
    case autoCompactReady
}

// MARK: - ContextBudgetState

/// 一次 evaluate() 调用的完整输出快照。
struct ContextBudgetState: Equatable, Sendable {
    let tokenUsage: Int
    let contextWindow: Int
    let effectiveContextWindow: Int
    let level: BudgetLevel
    let percentRemaining: Int

    var isAutoCompactReady: Bool { level == .autoCompactReady || level == .critical }
}

// MARK: - ContextWindowBudgetTracker

/// 纯无副作用的上下文预算计算器。
/// 不持有状态，任意线程可安全调用。
struct ContextWindowBudgetTracker: Sendable {

    /// 从 token 用量和 context window 大小计算当前预算级别。
    /// - Parameters:
    ///   - tokenUsage: 当前请求的累计输入 token 数（来自 countTokens 或 usage 字段）。
    ///   - contextWindow: 模型标称 context window 大小（例如 200_000）。
    func evaluate(tokenUsage: Int, contextWindow: Int) -> ContextBudgetState {
        let effectiveWindow = max(contextWindow - kMaxOutputTokensReserved, 1)

        let autoCompactThreshold = effectiveWindow - kAutocompactBufferTokens
        let warningThreshold     = effectiveWindow - kWarningBufferTokens

        let percentRemaining = max(
            0,
            Int(round(Double(effectiveWindow - tokenUsage) / Double(effectiveWindow) * 100))
        )

        let level: BudgetLevel
        if tokenUsage >= autoCompactThreshold {
            level = .autoCompactReady
        } else if tokenUsage >= warningThreshold {
            // warning 与 autoCompact 阈值之间的区域，对应 Claude Code 的 isAboveWarningThreshold
            level = .critical
        } else if tokenUsage >= warningThreshold - kWarningBufferTokens / 2 {
            // 给 UI 一个宽裕的 early warning 区间
            level = .warning
        } else {
            level = .normal
        }

        return ContextBudgetState(
            tokenUsage: tokenUsage,
            contextWindow: contextWindow,
            effectiveContextWindow: effectiveWindow,
            level: level,
            percentRemaining: percentRemaining
        )
    }
}

// MARK: - BudgetRunTracker

/// 单次 agent loop run 的 diminishing returns 检测器。
/// 每次 API 响应后调用 recordRound()；内部维护最多两个 delta 以检测连续低效输出。
///
/// 对应 Claude Code query/tokenBudget.ts 中的 BudgetTracker。
struct BudgetRunTracker: Sendable {

    private(set) var continuationCount: Int = 0
    private(set) var lastDeltaTokens: Int = 0
    private(set) var lastGlobalTurnTokens: Int = 0
    let startedAt: Date

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    struct RoundResult: Equatable, Sendable {
        let continuationCount: Int
        let currentDeltaTokens: Int
        let isDiminishing: Bool
    }

    /// 记录一次 round 的 token 消耗并返回检测结果。
    /// - Parameter currentGlobalTokens: 本次 round 结束后的累计会话 token 数。
    @discardableResult
    mutating func recordRound(currentGlobalTokens: Int) -> RoundResult {
        let delta = currentGlobalTokens - lastGlobalTurnTokens

        // Diminishing returns 检测：
        // continuationCount 已经 >= 3（对应 Claude Code continuationCount >= 3）
        // 且本次 delta 和上次 delta 都低于 DIMINISHING_THRESHOLD (500)
        let isDiminishing =
            continuationCount >= 3 &&
            delta < 500 &&
            lastDeltaTokens < 500

        continuationCount += 1
        lastDeltaTokens = delta
        lastGlobalTurnTokens = currentGlobalTokens

        return RoundResult(
            continuationCount: continuationCount,
            currentDeltaTokens: delta,
            isDiminishing: isDiminishing
        )
    }

    var durationMs: Int {
        Int(Date.now.timeIntervalSince(startedAt) * 1000)
    }
}
