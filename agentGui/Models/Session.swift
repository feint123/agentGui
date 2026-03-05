//
//  Session.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class Session {
    /// 唯一会话 ID
    var sessionId: String

    /// 显示标题（从第一条消息自动生成）
    var title: String

    /// 创建时间
    var createdAt: Date

    /// 最后更新时间
    var updatedAt: Date

    /// 是否活跃
    var isActive: Bool

    /// 关联的消息
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []

    init(
        sessionId: String = UUID().uuidString,
        title: String = "新对话"
    ) {
        self.sessionId = sessionId
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = false
    }
}

// MARK: - Computed Properties
extension Session {
    /// 是否为新会话（无消息）
    var isEmpty: Bool {
        messages.isEmpty
    }

    /// 最后一条消息
    var lastMessage: Message? {
        messages.sorted { $0.timestamp < $1.timestamp }.last
    }

    /// 最后一条消息的预览文本
    var lastMessagePreview: String {
        guard let last = lastMessage, let text = last.textContent, !text.isEmpty else {
            return "暂无消息"
        }
        return String(text.prefix(60))
    }

    /// 消息数量
    var messageCount: Int {
        messages.count
    }
}
