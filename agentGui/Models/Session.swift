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
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

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

    /// 会话级工作目录（空字符串表示使用全局 AppSettings.workingDirectory）
    var workingDirectory: String = ""

    /// 会话级默认执行器 ID
    var defaultExecutionProviderID: String = ConversationExecutionProviderID.builtInAgent.rawValue

    /// 持久化的会话来源类型。
    var kindRaw: String = SessionKind.local.rawValue

    /// 上游来源唯一标识，例如渠道会话 ID / 后台任务 ID。
    var sourceIdentifier: String = ""

    /// 上游来源展示名称，例如“飞书 · 团队群”或“日报任务”。
    var sourceDisplayName: String = ""

    /// 可选的只读提示文案覆盖值。
    var readOnlyReasonOverride: String = ""

    /// Serialised `ExecutionPlan` JSON for this session.
    /// Written by the `create_execution_plan` tool (regular tasks) and mirrored from
    /// the workflow runtime when a plan artifact is produced, so both paths share the
    /// same persistent record.  Use the computed `plan` property to decode it.
    var planJson: String = ""

    /// Serialised session-scoped execution preferences for provider-specific composer overrides.
    var executionPreferencesJSON: String = "{}"

    /// 关联的消息
    @Relationship(deleteRule: .cascade, inverse: \Message.session)
    var messages: [Message] = []

    /// 关联的远端会话绑定
    @Relationship(deleteRule: .cascade, inverse: \RemoteConversationBinding.session)
    var remoteConversationBindings: [RemoteConversationBinding] = []

    /// 关联的投影绑定
    @Relationship(deleteRule: .cascade, inverse: \SessionProjectionBinding.session)
    var projectionBindings: [SessionProjectionBinding] = []

    /// 关联的渠道投影投递记录
    @Relationship(deleteRule: .cascade, inverse: \ChannelProjectionDelivery.session)
    var projectionDeliveries: [ChannelProjectionDelivery] = []

    init(
        sessionId: String = UUID().uuidString,
        title: String = "新对话",
        kind: SessionKind = .local,
        sourceIdentifier: String = "",
        sourceDisplayName: String = "",
        readOnlyReasonOverride: String = ""
    ) {
        self.sessionId = sessionId
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = false
        self.kindRaw = kind.rawValue
        self.sourceIdentifier = sourceIdentifier
        self.sourceDisplayName = sourceDisplayName
        self.readOnlyReasonOverride = readOnlyReasonOverride
    }
}

// MARK: - Computed Properties
extension Session {
    var kind: SessionKind {
        get { SessionKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    var executionProviderID: ConversationExecutionProviderID {
        ConversationExecutionProviderID(rawValue: defaultExecutionProviderID) ?? .builtInAgent
    }

    var isReadOnly: Bool {
        kind.isReadOnlyByDefault
    }

    var readOnlyReason: String {
        if !readOnlyReasonOverride.isEmpty {
            return readOnlyReasonOverride
        }
        return kind.defaultReadOnlyReason
    }

    var displaySourceTitle: String {
        if !sourceDisplayName.isEmpty {
            return sourceDisplayName
        }
        return kind.defaultSourceTitle
    }

    /// Decoded `ExecutionPlan` for this session, or `nil` if none has been created yet.
    var plan: ExecutionPlan? {
        guard !planJson.isEmpty, let data = planJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutionPlan.self, from: data)
    }

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

    @MainActor
    static func fixture(
        sessionId: String = UUID().uuidString,
        title: String = "Test Session",
        workingDirectory: String = "",
        kind: SessionKind = .local,
        sourceIdentifier: String = "",
        sourceDisplayName: String = "",
        readOnlyReasonOverride: String = ""
    ) -> Session {
        let session = Session(
            sessionId: sessionId,
            title: title,
            kind: kind,
            sourceIdentifier: sourceIdentifier,
            sourceDisplayName: sourceDisplayName,
            readOnlyReasonOverride: readOnlyReasonOverride
        )
        session.workingDirectory = workingDirectory
        return session
    }
}

