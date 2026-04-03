import Foundation
import SwiftAnthropic

// MARK: - CompactionError

enum CompactionError: LocalizedError {
    case serviceNotConfigured
    case emptySummaryResponse
    case circuitBreakerTripped

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:  return "CompactionError: AnthropicService is not configured."
        case .emptySummaryResponse:  return "CompactionError: API returned empty summary text."
        case .circuitBreakerTripped: return "CompactionError: circuit breaker tripped, skipping compaction."
        }
    }
}

// MARK: - ClaudeService+Compaction

extension ClaudeService {

    // MARK: - Prompt

    /// 遵循 Claude Code BASE_COMPACT_PROMPT 的 9 节结构摘要提示词。
    /// 以 user 消息形式追加到消息列表尾部，不需要单独 system 参数。
    private static let compactionRequestMessage = """
    Please create a detailed summary of the conversation above. This summary will replace the full conversation history to preserve context while reducing token usage.

    Your summary MUST include these sections:

    1. **Primary Request and Intent** — What the user wants to accomplish (full detail, not abbreviated)
    2. **Key Technical Concepts** — Technologies, frameworks, APIs, architectures discussed
    3. **Files and Code Sections** — Every file examined or modified; include key code snippets, function signatures, and why each file mattered
    4. **Errors and Fixes** — Problems encountered, error messages, and how they were resolved; note any user-specific feedback or corrections
    5. **Problem Solving** — Decisions made, trade-offs discussed, approaches tried and discarded
    6. **All User Messages** — Verbatim or very close paraphrase of every user message (not tool results); these capture changing intent
    7. **Pending Tasks** — All work explicitly requested but not yet completed
    8. **Current Work** — Exactly what was being worked on immediately before this summary, with file paths and code snippets where relevant
    9. **Next Step** — The single most logical next action, directly derived from the most recent user request

    Output plain Markdown. Do not include XML tags, code fences around the whole response, or meta-commentary.
    Be thorough: this summary is the only context the assistant will have going forward.
    """

    // MARK: - Public

    /// 调用 Claude API 为当前对话历史生成压缩摘要文本。
    ///
    /// 使用 `service.createMessage()` 非流式调用，不影响主 agent loop 的消息时间线。
    /// 最大输出 token 设为 8192（同 Claude Code COMPACT_MAX_OUTPUT_TOKENS = 8192）。
    ///
    /// - Parameters:
    ///   - messages: 压缩前的完整消息数组（不含摘要请求消息本身）。
    ///   - modelId: 用于生成摘要的模型 ID（通常与主 loop 相同）。
    /// - Returns: 摘要文本（非空）。
    /// - Throws: `CompactionError.serviceNotConfigured` 或 `CompactionError.emptySummaryResponse`，或来自 API 的错误。
    func generateCompactionSummary(
        messages: [MessageParameter.Message],
        modelId: String
    ) async throws -> String {
        guard let service else { throw CompactionError.serviceNotConfigured }

        // 构建消息序列：完整历史 + 摘要请求
        var summaryMessages = messages
        summaryMessages.append(
            MessageParameter.Message(role: .user, content: .text(Self.compactionRequestMessage))
        )

        let params = MessageParameter(
            model: .other(modelId),
            messages: summaryMessages,
            maxTokens: 8192
        )

        let response = try await service.createMessage(params)
        let summaryText = response.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()

        guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompactionError.emptySummaryResponse
        }

        return summaryText
    }
}
