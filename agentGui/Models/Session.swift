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
    /// 唯一会话 ID (对应 ACP SessionId)
    var sessionId: String

    /// 显示标题 (从第一条消息或工作目录生成)
    var title: String

    /// 工作目录
    var workingDirectory: String

    /// 当前模式
    var mode: SessionMode

    /// 当前模型 ID
    var currentModel: String?

    /// 创建时间
    var createdAt: Date

    /// 最后更新时间
    var updatedAt: Date

    /// 是否活跃 (Agent 已连接)
    var isActive: Bool

    /// 关联的 Agent 配置
    var agent: AgentConfiguration?

    /// 关联的消息
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []

    init(
        sessionId: String = UUID().uuidString,
        title: String,
        workingDirectory: String,
        agent: AgentConfiguration? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.workingDirectory = workingDirectory
        self.mode = .chat
        self.currentModel = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = false
        self.agent = agent
    }
}

// MARK: - Computed Properties
extension Session {
    /// 工作目录显示名称
    var directoryName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    /// 是否为新会话（无消息）
    var isNew: Bool {
        messages.isEmpty
    }

    /// 最后一条消息
    var lastMessage: Message? {
        messages.sorted { $0.timestamp > $1.timestamp }.first
    }

    /// 消息数量
    var messageCount: Int {
        messages.count
    }

    /// 会话时长
    var duration: TimeInterval {
        updatedAt.timeIntervalSince(createdAt)
    }

    /// 生成默认标题
    static func generateTitle(from workingDirectory: String, firstMessage: String? = nil) -> String {
        let dirName = (workingDirectory as NSString).lastPathComponent

        if let message = firstMessage, !message.isEmpty {
            let prefix = String(message.prefix(30))
            return prefix == message ? "\(dirName) - \(prefix)" : "\(dirName) - \(prefix)..."
        }

        return dirName.isEmpty ? "新会话" : dirName
    }
}
