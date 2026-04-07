//
//  Message.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class Message {
    /// 唯一标识符
    var id: UUID

    /// 消息方向
    var direction: MessageDirection

    /// 内容类型
    var contentType: ContentType

    /// 文本内容
    var textContent: String?

    /// 消息状态
    var status: MessageStatus

    /// 序列号 (用于排序)
    var sequence: Int

    /// 时间戳
    var timestamp: Date

    /// 错误信息 (如果状态为失败)
    var errorMessage: String?

    /// 关联的会话
    var session: Session?

    /// 关联的工具调用
    @Relationship(deleteRule: .cascade, inverse: \ToolCall.message)
    var toolCalls: [ToolCall] = []

    /// 关联的 Agentic Loop 轮次
    @Relationship(deleteRule: .cascade, inverse: \AgentRound.message)
    var agentRounds: [AgentRound] = []

    /// 结构化文件附件（CV-F1：替代 textContent 中的 "Referenced files:" 段落）
    @Relationship(deleteRule: .cascade, inverse: \MessageAttachment.message)
    var attachments: [MessageAttachment] = []

    init(
        direction: MessageDirection,
        contentType: ContentType = .text,
        text: String? = nil,
        session: Session? = nil
    ) {
        self.id = UUID()
        self.direction = direction
        self.contentType = contentType
        self.textContent = text
        self.status = .pending
        self.sequence = 0
        self.timestamp = Date()
        self.errorMessage = nil
        self.session = session
    }
}

// MARK: - Computed Properties
extension Message {
    /// 是否为用户消息
    var isUserMessage: Bool {
        direction == .user
    }

    /// 是否为系统消息
    var isSystemMessage: Bool {
        direction == .system
    }

    /// 是否已完成
    var isCompleted: Bool {
        status == .completed
    }

    /// 是否失败
    var isFailed: Bool {
        status == .failed
    }

    /// 是否有工具调用
    var hasToolCalls: Bool {
        !toolCalls.isEmpty
    }

    /// 格式化显示时间
    var displayTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: timestamp)
    }

    /// 格式化显示日期（用于跨天消息）
    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: timestamp)
    }
}

// MARK: - Factory Methods
extension Message {
    /// 创建用户消息
    static func userMessage(text: String, session: Session) -> Message {
        let message = Message(direction: .user, contentType: .text, text: text, session: session)
        message.sequence = (session.messages.map(\.sequence).max() ?? 0) + 1
        return message
    }

    /// 创建 Agent 消息
    static func agentMessage(text: String?, session: Session) -> Message {
        let message = Message(direction: .agent, contentType: .text, text: text, session: session)
        message.sequence = (session.messages.map(\.sequence).max() ?? 0) + 1
        return message
    }

    /// 创建系统消息
    static func systemMessage(text: String, session: Session) -> Message {
        let message = Message(direction: .system, contentType: .text, text: text, session: session)
        message.sequence = (session.messages.map(\.sequence).max() ?? 0) + 1
        message.status = .completed
        return message
    }

    /// 创建错误消息
    static func errorMessage(text: String, session: Session) -> Message {
        let message = Message(direction: .system, contentType: .error, text: text, session: session)
        message.sequence = (session.messages.map(\.sequence).max() ?? 0) + 1
        message.status = .failed
        return message
    }

    @MainActor
    static func userFixture(
        text: String = "User input",
        session: Session? = nil,
        status: MessageStatus = .completed
    ) -> Message {
        let resolvedSession = session ?? Session.fixture(title: "Fixture Session")
        let message = Message(direction: .user, contentType: .text, text: text, session: resolvedSession)
        message.sequence = (resolvedSession.messages.map(\.sequence).max() ?? 0) + 1
        message.status = status
        return message
    }

    @MainActor
    static func agentFixture(
        text: String = "Agent response",
        session: Session? = nil,
        status: MessageStatus = .completed
    ) -> Message {
        let resolvedSession = session ?? Session.fixture(title: "Fixture Session")
        let message = Message(direction: .agent, contentType: .text, text: text, session: resolvedSession)
        message.sequence = (resolvedSession.messages.map(\.sequence).max() ?? 0) + 1
        message.status = status
        return message
    }
}
