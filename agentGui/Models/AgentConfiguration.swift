//
//  AgentConfiguration.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class AgentConfiguration {
    /// 唯一标识符
    var id: UUID

    /// 显示名称
    var name: String

    /// Agent 类型/来源
    var agentType: AgentType

    /// 连接类型
    var connectionType: ConnectionType

    /// 本地可执行文件路径 (stdio)
    var executablePath: String?

    /// 命令行参数
    var arguments: [String]

    /// 远程服务 URL (WebSocket)
    var remoteURL: String?

    /// 认证令牌 (加密存储)
    var authToken: String?

    /// 工作目录 (默认值)
    var defaultWorkingDirectory: String

    /// 环境变量
    var environmentVariables: [String: String]

    /// 是否自动连接
    var autoConnect: Bool

    /// 创建时间
    var createdAt: Date

    /// 最后使用时间
    var lastUsedAt: Date?

    /// 排序顺序
    var sortOrder: Int

    /// 关联的会话
    @Relationship(deleteRule: .cascade, inverse: \Session.agent)
    var sessions: [Session] = []

    init(
        name: String,
        agentType: AgentType = .claudeCode,
        connectionType: ConnectionType = .stdio,
        executablePath: String? = nil,
        remoteURL: String? = nil,
        authToken: String? = nil,
        defaultWorkingDirectory: String = NSHomeDirectory(),
        autoConnect: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.agentType = agentType
        self.connectionType = connectionType
        self.executablePath = executablePath
        self.arguments = []
        self.remoteURL = remoteURL
        self.authToken = authToken
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.environmentVariables = [:]
        self.autoConnect = autoConnect
        self.createdAt = Date()
        self.lastUsedAt = nil
        self.sortOrder = 0
    }
}

// MARK: - Computed Properties
extension AgentConfiguration {
    /// 是否为本地 stdio 连接
    var isLocal: Bool {
        return connectionType == .stdio
    }

    /// 是否已配置
    var isConfigured: Bool {
        if isLocal {
            return executablePath != nil && !executablePath!.isEmpty
        } else {
            return remoteURL != nil && !remoteURL!.isEmpty
        }
    }

    /// 完整的 Agent 命令（用于显示）
    var commandDisplay: String {
        if isLocal, let path = executablePath {
            return path
        } else if let url = remoteURL {
            return url
        }
        return "未配置"
    }
}
