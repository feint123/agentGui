//
//  AgentRound.swift
//  agentGui
//

import SwiftData
import Foundation

/// 代表 agentic loop 的一次迭代（一轮 API 调用）
@Model
final class AgentRound {
    /// 唯一标识符
    var id: UUID

    /// 轮次序号（0-based，在同一 Message 内递增）
    var roundIndex: Int

    /// 本轮 Claude 生成的文本内容
    var text: String?

    /// Extended Thinking 内容（思考过程）
    var thinkingContent: String?

    /// Extended Thinking 签名（multi-turn 对话必须携带回 API）
    var thinkingSignature: String?

    /// 时间戳
    var timestamp: Date

    /// 关联的消息
    var message: Message?

    /// 本轮的工具调用列表
    @Relationship(deleteRule: .cascade, inverse: \ToolCall.agentRound)
    var toolCalls: [ToolCall] = []

    init(roundIndex: Int, message: Message) {
        self.id = UUID()
        self.roundIndex = roundIndex
        self.timestamp = Date()
        self.message = message
    }
}

// MARK: - Computed Properties
extension AgentRound {
    /// 是否包含 thinking 内容
    var hasThinking: Bool {
        guard let content = thinkingContent else { return false }
        return !content.isEmpty
    }

    /// 是否包含文本内容
    var hasText: Bool {
        guard let t = text else { return false }
        return !t.isEmpty
    }

    /// 本轮工具调用（按开始时间排序）
    var sortedToolCalls: [ToolCall] {
        toolCalls.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
    }
}
