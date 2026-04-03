import Foundation
import SwiftAnthropic

// MARK: - CompactionEngine

/// 纯无副作用的消息压缩变换器。
/// 职责：
///   1. 用 MessageInvariantValidator 计算安全截断起点（proposeCutIndex）
///   2. 将摘要文本 + 保留尾部拼装成新消息数组，可选附加 session memory（buildCompactedMessages）
///
/// 摘要消息结构（两层）：
///   1. `<summary>` —— Claude API 生成的 9 节 Markdown 摘要
///   2. `### Session Memory` —— M-11 summary.md 内容（可选，文件不存在时省略）
///
/// 对应 Claude Code compact.ts 中 buildPostCompactMessages() + sessionMemoryCompact.ts 的不变量对齐逻辑。
struct CompactionEngine: Sendable {

    private let validator = MessageInvariantValidator()

    /// 保留末尾消息的默认比例（25%），最少 8 条。
    static let defaultKeepRecentFraction: Double = 0.25
    static let minimumKeepRecentCount: Int = 8

    // MARK: - Public API

    /// 计算安全截断起点。保留 `messages[cutIndex...]`，截断 `messages[..<cutIndex]`。
    ///
    /// 先按比例算 rawCut，再通过 `MessageInvariantValidator.adjustedStartIndex()` 向前调整，
    /// 确保 kept range 内的 tool_result 都能在 kept range 内找到对应 tool_use。
    ///
    /// - Parameters:
    ///   - messages: 完整消息数组。
    ///   - keepRecentFraction: 末尾保留比例（默认 0.25）。
    /// - Returns: 安全截断起点，范围 `[0, messages.count]`。
    func proposeCutIndex(
        in messages: [MessageParameter.Message],
        keepRecentFraction: Double = CompactionEngine.defaultKeepRecentFraction
    ) -> Int {
        guard !messages.isEmpty else { return 0 }
        let keepCount = max(
            Self.minimumKeepRecentCount,
            Int(Double(messages.count) * keepRecentFraction)
        )
        let rawCut = max(0, messages.count - keepCount)
        return validator.adjustedStartIndex(rawCut, in: messages)
    }

    /// 构建压缩后消息数组。
    ///
    /// 结构：`[summaryUserMessage] + messages[cutIndex...]`
    ///
    /// summaryUserMessage 格式：
    /// ```
    /// [Conversation history has been compacted]
    ///
    /// <summary>
    /// {summaryText}
    /// </summary>
    ///
    /// --- (仅在 sessionSummary 非空时出现)
    /// ### Session Memory
    /// {sessionSummary}
    /// ```
    ///
    /// - Parameters:
    ///   - original: 压缩前完整消息数组。
    ///   - summaryText: 对话历史摘要（来自 ClaudeService API）。
    ///   - cutIndex: proposeCutIndex() 的返回值。
    ///   - sessionSummary: 可选 M-11 session memory（summary.md 内容），作为附加节注入。
    /// - Returns: 新消息数组。
    func buildCompactedMessages(
        original: [MessageParameter.Message],
        summaryText: String,
        cutIndex: Int,
        sessionSummary: String? = nil
    ) -> [MessageParameter.Message] {
        let keptMessages = cutIndex < original.count ? Array(original[cutIndex...]) : []

        var content = "[Conversation history has been compacted]\n\n<summary>\n\(summaryText)\n</summary>"

        // 注入 M-11 session memory（summary.md）—— 对应 Claude Code trySessionMemoryCompaction() 路径
        if let sessionMem = sessionSummary, !sessionMem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "\n\n---\n### Session Memory\n\(sessionMem)"
        }

        let summaryMessage = MessageParameter.Message(role: .user, content: .text(content))
        return [summaryMessage] + keptMessages
    }
}
