# 数据模型设计: AI Agent 客户端

**日期**: 2026-02-10
**功能**: AI Agent 客户端
**状态**: 完成

## 概述

本文档定义 AI Agent 客户端的 SwiftData 数据模型。所有模型遵循 Swift 6 并发安全原则，使用 `@Model` 宏定义。

## 核心实体关系图

```
┌─────────────────┐       ┌──────────────┐       ┌─────────────┐
│ AppSettings     │       │AgentConfig  │       │  Session    │
│ (单例)          │       │              │       │             │
└─────────────────┘       └──────┬───────┘       └──────┬──────┘
                                 │ 1                    │ 1
                                 │                      │
                                 │ N                    │ N
                          ┌──────┴───────┐      ┌─────┴─────┐
                          │   Message   │      │ Permission │
                          │             │◄─────│ Request   │
                          └─────────────┘ 1    │ (可选)    │
                             │         │        └───────────┘
                             │ 1       │ N
                             │         │
                          ┌──┴─────┐  │
                          │ToolCall│  │
                          └────────┘  │
                                      │
                                 (会话关联)
```

## 模型定义

### 1. AgentConfiguration (Agent 配置)

表示一个 AI Agent 服务的配置信息。

```swift
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

    init(
        name: String,
        agentType: AgentType,
        connectionType: ConnectionType,
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

/// Agent 类型枚举
enum AgentType: String, Codable {
    case claudeCode = "claude-code"
    case openCode = "opencode"
    case custom = "custom"
}

/// 连接类型枚举
enum ConnectionType: String, Codable {
    case stdio = "stdio"       // 本地进程
    case websocket = "websocket" // 远程服务
}
```

### 2. Session (会话)

表示与 Agent 的一次对话上下文。

```swift
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

    /// 关联的 Agent 配置
    @Relationship(deleteRule: .nullify, inverse: \AgentConfiguration?.sessions)
    var agent: AgentConfiguration?

    /// 创建时间
    var createdAt: Date

    /// 最后更新时间
    var updatedAt: Date

    /// 是否活跃 (Agent 已连接)
    var isActive: Bool

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
        self.agent = agent
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isActive = false
    }
}

/// 会话模式枚举
enum SessionMode: String, Codable {
    case code = "code"       // 代码模式
    case chat = "chat"       // 聊天模式
    case plan = "plan"       // 计划模式
    case ask = "ask"         // 询问模式
}
```

### 3. Message (消息)

表示对话中的一条消息。

```swift
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

    /// 关联的会话
    @Relationship(deleteRule: .cascade, inverse: \Session?.messages)
    var session: Session?

    /// 序列号 (用于排序)
    var sequence: Int

    /// 时间戳
    var timestamp: Date

    /// 错误信息 (如果状态为失败)
    var errorMessage: String?

    init(
        direction: MessageDirection,
        contentType: ContentType,
        text: String? = nil,
        session: Session
    ) {
        self.id = UUID()
        self.direction = direction
        self.contentType = contentType
        self.textContent = text
        self.status = .pending
        self.session = session
        self.sequence = 0
        self.timestamp = Date()
        self.errorMessage = nil
    }
}

/// 消息方向枚举
enum MessageDirection: String, Codable {
    case user = "user"           // 用户发送
    case agent = "agent"         // Agent 响应
    case system = "system"       // 系统消息
}

/// 内容类型枚举
enum ContentType: String, Codable {
    case text = "text"           // 纯文本
    case toolCall = "tool_call"  // 工具调用
    case thought = "thought"     // 思考过程
    case error = "error"         // 错误信息
}

/// 消息状态枚举
enum MessageStatus: String, Codable {
    case pending = "pending"     // 发送中
    case completed = "completed" // 已完成
    case failed = "failed"       // 失败
    case cancelled = "cancelled" // 已取消
}
```

### 4. ToolCall (工具调用)

表示 Agent 执行的工具操作。

```swift
@Model
final class ToolCall {
    /// 唯一标识符
    var id: UUID

    /// 工具调用 ID (来自 ACP)
    var toolCallId: String

    /// 工具类型
    var kind: ToolKind

    /// 显示标题
    var title: String?

    /// 状态
    var status: ToolStatus

    /// 关联的文件路径
    var filePath: String?

    /// Diff 内容 (用于编辑操作)
    var diffContent: String?

    /// 终端输出
    var terminalOutput: String?

    /// 开始时间
    var startTime: Date?

    /// 结束时间
    var endTime: Date?

    /// 关联的消息
    @Relationship(deleteRule: .cascade, inverse: \Message?.toolCalls)
    var message: Message?

    init(
        toolCallId: String,
        kind: ToolKind,
        message: Message
    ) {
        self.id = UUID()
        self.toolCallId = toolCallId
        self.kind = kind
        self.status = .inProgress
        self.title = nil
        self.filePath = nil
        self.diffContent = nil
        self.terminalOutput = nil
        self.startTime = Date()
        self.endTime = nil
        self.message = message
    }
}

/// 工具类型枚举
enum ToolKind: String, Codable {
    case read = "read"
    case edit = "edit"
    case execute = "execute"
    case search = "search"
    case delete = "delete"
    case think = "think"
    case fetch = "fetch"
    case plan = "plan"
    case switchMode = "switch_mode"
    case other = "other"
}

/// 工具状态枚举
enum ToolStatus: String, Codable {
    case inProgress = "in_progress"
    case success = "success"
    case failed = "failed"
    case cancelled = "cancelled"
}
```

### 5. PermissionRequest (权限请求)

表示 Agent 的敏感操作请求记录。

```swift
@Model
final class PermissionRequest {
    /// 唯一标识符
    var id: UUID

    /// 请求类型
    var requestType: PermissionType

    /// 目标资源路径
    var resourcePath: String

    /// 用户决定
    var decision: PermissionDecision

    /// 是否记住选择
    var rememberChoice: Bool

    /// 请求时间
    var timestamp: Date

    /// 关联的会话
    @Relationship(deleteRule: .nullify)
    var session: Session?

    init(
        requestType: PermissionType,
        resourcePath: String,
        session: Session? = nil
    ) {
        self.id = UUID()
        self.requestType = requestType
        self.resourcePath = resourcePath
        self.decision = .pending
        self.rememberChoice = false
        self.timestamp = Date()
        self.session = session
    }
}

/// 权限类型枚举
enum PermissionType: String, Codable {
    case fileRead = "file_read"
    case fileWrite = "file_write"
    case terminalCreate = "terminal_create"
    case networkRequest = "network_request"
}

/// 权限决定枚举
enum PermissionDecision: String, Codable {
    case pending = "pending"
    case allowed = "allowed"
    case denied = "denied"
}
```

### 6. AppSettings (应用设置)

应用全局偏好设置（单例）。

```swift
@Model
final class AppSettings {
    /// 主题模式
    var themeMode: ThemeMode

    /// 自动批准策略
    var autoApprovePolicy: AutoApprovePolicy

    /// 启动时自动连接上次 Agent
    var autoConnectOnStartup: Bool

    /// 默认 Agent ID
    var defaultAgentId: UUID?

    /// 最大会话历史数量
    var maxSessionHistory: Int

    /// 消息字体大小
    var messageFontSize: Double

    /// 是否显示工具调用详情
    var showToolCallDetails: Bool

    init() {
        self.themeMode = .system
        self.autoApprovePolicy = .askAlways
        self.autoConnectOnStartup = false
        self.defaultAgentId = nil
        self.maxSessionHistory = 1000
        self.messageFontSize = 13.0
        self.showToolCallDetails = true
    }
}

/// 主题模式枚举
enum ThemeMode: String, Codable {
    case light = "light"
    case dark = "dark"
    case system = "system"
}

/// 自动批准策略枚举
enum AutoApprovePolicy: String, Codable {
    case askAlways = "ask_always"           // 总是询问
    case approveReads = "approve_reads"     // 自动批准读操作
    case approveAll = "approve_all"         // 自动批准所有
}
```

## 数据库索引

为优化查询性能，以下字段应建立索引：

```swift
// ModelContainer 配置中的索引
let schema = Schema([
    AgentConfiguration.self,
    Session.self,
    Message.self,
    ToolCall.self,
    PermissionRequest.self,
    AppSettings.self
], indexes: {
    // 会话按更新时间排序
    IndexDescription(Session.self, \Session.updatedAt)

    // 消息按会话和时间戳查询
    IndexDescription(Message.self, \Message.session?.sessionId)
    IndexDescription(Message.self, \Message.timestamp)

    // 权限请求按时间查询
    IndexDescription(PermissionRequest.self, \PermissionRequest.timestamp)
})
```

## 迁移策略

SwiftData 的轻量级迁移可以自动处理以下变更：
- 添加新属性（提供默认值）
- 删除属性
- 修改属性类型（兼容类型）

对于破坏性变更（如关系修改），需要使用 VersionedSchema：

```swift
enum AgentClientSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [AgentConfiguration.self, Session.self, Message.self,
         ToolCall.self, PermissionRequest.self, AppSettings.self]
    }
}

enum AgentClientSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        // 新增模型或修改后的模型
    }

    static var migrationStage: MigrationStage {
        .migrate(from: AgentClientSchemaV1.self, to: AgentClientSchemaV2.self) {
            // 迁移逻辑
        }
    }
}
```

## 内存数据模型

以下数据仅保存在内存中（Actor），不持久化：

```swift
/// Agent 连接状态 (内存中)
struct AgentConnectionState {
    var agentId: UUID
    var isConnected: Bool
    var processId: Int32?
    var activeSessionIds: Set<String>
}

/// 流式响应缓冲 (内存中)
struct StreamingBuffer {
    var sessionId: String
    var messageId: UUID
    var accumulatedText: String
    var pendingToolCalls: [ToolCall]
}
```
