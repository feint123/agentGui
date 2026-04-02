import Foundation

/// 对齐 Claude Code `sessionMemoryUtils.ts` 中的模块级状态变量。
///
/// 以 actor 形式封装每个 session 的 session memory 提取状态，
/// 跨 `runCoreAgentLoop` 调用持久驻留（存放在 `ClaudeService.sessionMemoryStates`）。
actor SessionMemoryState {

    // MARK: - Config（对齐 Claude Code DEFAULT_SESSION_MEMORY_CONFIG）

    static let minimumTokensToInit = 10_000
    static let minimumTokensBetweenUpdate = 5_000
    static let toolCallsBetweenUpdates = 3

    // MARK: - State

    private var initialized = false
    private var tokensAtLastExtraction = 0
    private var toolCallsSinceLastExtraction = 0
    private var extractionInProgress = false
    private var extractionStartedAt: Date?

    // MARK: - Extraction Gate

    /// 检查是否应触发 session memory 更新。
    ///
    /// 对齐 Claude Code `shouldExtractMemory`：
    /// - 首次需满足 init 阈值
    /// - 此后需满足 token 增量阈值，且（tool call 阈值满足 OR 无工具调用的自然对话断点）
    func shouldExtract(estimatedTokens: Int, toolCallsThisRound: Int) -> Bool {
        toolCallsSinceLastExtraction += toolCallsThisRound

        if !initialized {
            guard estimatedTokens >= Self.minimumTokensToInit else { return false }
            initialized = true
        }

        let tokenGrowth = estimatedTokens - tokensAtLastExtraction
        let hasMetTokenThreshold = tokenGrowth >= Self.minimumTokensBetweenUpdate
        guard hasMetTokenThreshold else { return false }

        let hasMetToolCallThreshold = toolCallsSinceLastExtraction >= Self.toolCallsBetweenUpdates
        let isNaturalBreak = (toolCallsThisRound == 0)

        return hasMetToolCallThreshold || isNaturalBreak
    }

    /// 提取完成后调用，更新 token 基线并重置工具调用计数。
    func recordExtraction(estimatedTokens: Int) {
        tokensAtLastExtraction = estimatedTokens
        toolCallsSinceLastExtraction = 0
    }

    // MARK: - Concurrency Guard（对齐 Claude Code sequential + extractionStartedAt 机制）

    /// 尝试开始提取。若已有提取在进行中则返回 false。
    func beginExtraction() -> Bool {
        guard !extractionInProgress else { return false }
        extractionInProgress = true
        extractionStartedAt = Date()
        return true
    }

    /// 标记提取完成。
    func finishExtraction() {
        extractionInProgress = false
        extractionStartedAt = nil
    }

    /// 等待当前提取完成（带超时）。对齐 Claude Code `waitForSessionMemoryExtraction`。
    func waitForExtraction(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while extractionInProgress {
            guard Date() < deadline else { return }
            // 过期检测：>1 分钟的提取视为 stale
            if let startedAt = extractionStartedAt,
               Date().timeIntervalSince(startedAt) > 60 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms poll
        }
    }
}
