# 模块契约: AI Agent 客户端

**日期**: 2026-02-10
**功能**: AI Agent 客户端

## 概述

本文档定义 AI Agent 客户端各模块间的接口契约，确保模块间松耦合、可测试。

## 模块依赖关系

```
┌─────────────────────────────────────────────────────────┐
│                       Views (SwiftUI)                   │
│  AgentListView | SessionListView | ChatView | ...       │
└──────────────────────────────┬──────────────────────────┘
                               │ (仅依赖 ViewModels)
                               ▼
┌─────────────────────────────────────────────────────────┐
│                    ViewModels (@Observable)             │
│  AgentListViewModel | SessionViewModel | ChatViewModel  │
└──────────────────────────────┬──────────────────────────┘
                               │ (依赖 Services)
                               ▼
┌─────────────────────────────────────────────────────────┐
│                      Services (Actor)                    │
│  ACPClientService | AgentLifecycleService | ...         │
└──────────────────────────────┬──────────────────────────┘
                               │ (依赖 Repositories)
                               ▼
┌─────────────────────────────────────────────────────────┐
│                    Repositories                          │
│  AgentRepository | SessionRepository | MessageRepository│
└──────────────────────────────┬──────────────────────────┘
                               │ (依赖 SwiftData)
                               ▼
┌─────────────────────────────────────────────────────────┐
│                    SwiftData Models                     │
│  AgentConfiguration | Session | Message | ...           │
└─────────────────────────────────────────────────────────┘
```

## 契约 1: ACPClientService

**职责**: 封装 swift-acp Client，提供 Agent 通信能力

**协议定义**:

```swift
/// ACP 客户端服务协议
protocol ACPClientServiceProtocol: Sendable {
    /// 连接 Agent
    func connect(agent: AgentConfiguration) async throws

    /// 断开连接
    func disconnect() async

    /// 创建会话
    func createSession(
        workingDirectory: String
    ) async throws -> Session

    /// 发送提示
    func sendPrompt(
        _ text: String,
        to sessionId: String
    ) async throws

    /// 取消会话
    func cancelSession(sessionId: String) async throws

    /// 设置模式
    func setMode(
        sessionId: String,
        mode: SessionMode
    ) async throws

    /// 订阅会话更新
    func subscribeToUpdates(
        sessionId: String
    ) -> AsyncStream<SessionUpdate>

    /// 当前连接状态
    var connectionState: ConnectionState { get async }
}

/// 连接状态
enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connected(agentInfo: AgentInfo)
    case error(Error)
}

/// 会话更新事件
enum SessionUpdate: Sendable {
    case messageChunk(MessageChunk)
    case toolCall(ToolCallEvent)
    case modeChanged(SessionMode)
    case error(Error)
}
```

**实现要求**:
- MUST 是 Actor
- MUST 使用 swift-acp 的 Client 类型
- MUST 线程安全
- MUST 处理所有 ClientError 并转换为应用错误类型

## 契约 2: AgentRepository

**职责**: Agent 配置的数据访问层

**协议定义**:

```swift
/// Agent 仓库协议
protocol AgentRepositoryProtocol: Sendable {
    /// 获取所有 Agent 配置
    func fetchAll() async throws -> [AgentConfiguration]

    /// 按 ID 获取
    func fetch(byId id: UUID) async throws -> AgentConfiguration?

    /// 创建或更新
    func save(_ agent: AgentConfiguration) async throws

    /// 删除
    func delete(_ agent: AgentConfiguration) async throws

    /// 更新最后使用时间
    func updateLastUsed(id: UUID) async throws

    /// 获取默认 Agent
    func fetchDefault() async throws -> AgentConfiguration?
}
```

**实现要求**:
- MUST 使用 SwiftData ModelContext
- MUST 在 MainActor 或 ModelContext 的正确执行上下文中执行
- MUST 处理 SwiftData 错误

## 契约 3: SessionRepository

**职责**: 会话数据访问层

**协议定义**:

```swift
/// 会话仓库协议
protocol SessionRepositoryProtocol: Sendable {
    /// 获取所有会话
    func fetchAll() async throws -> [Session]

    /// 按 ID 获取
    func fetch(byId id: String) async throws -> Session?

    /// 按 Agent 获取会话列表
    func fetch(byAgentId agentId: UUID) async throws -> [Session]

    /// 创建会话
    func create(_ session: Session) async throws

    /// 更新会话
    func update(_ session: Session) async throws

    /// 删除会话
    func delete(_ session: Session) async throws

    /// 获取最近使用的会话
    func fetchRecent(limit: Int) async throws -> [Session]
}
```

## 契约 4: MessageRepository

**职责**: 消息数据访问层

**协议定义**:

```swift
/// 消息仓库协议
protocol MessageRepositoryProtocol: Sendable {
    /// 获取会话的所有消息
    func fetch(bySessionId sessionId: String) async throws -> [Message]

    /// 添加消息
    func add(_ message: Message) async throws

    /// 批量添加消息
    func add(_ messages: [Message]) async throws

    /// 更新消息状态
    func updateStatus(
        messageId: UUID,
        status: MessageStatus
    ) async throws

    /// 删除会话的所有消息
    func deleteBySessionId(_ sessionId: String) async throws

    /// 获取消息数量
    func count(bySessionId sessionId: String) async throws -> Int
}
```

## 契约 5: PermissionManager

**职责**: 处理权限请求和用户决定

**协议定义**:

```swift
/// 权限管理器协议
protocol PermissionManagerProtocol: Actor {
    /// 请求权限
    func requestPermission(
        _ request: PermissionRequest
    ) async -> PermissionDecision

    /// 检查是否已自动批准
    func checkAutoApprove(
        type: PermissionType,
        path: String
    ) -> Bool

    /// 记录用户决定
    func recordDecision(
        request: PermissionRequest,
        decision: PermissionDecision,
        remember: Bool
    ) async

    /// 获取权限历史
    func getHistory(
        sessionId: String,
        limit: Int
    ) async throws -> [PermissionRequest]
}
```

## 契约 6: AgentListViewModel

**职责**: Agent 列表的 UI 状态管理

**协议定义**:

```swift
@Observable
@MainActor
class AgentListViewModel {
    /// Agent 列表
    var agents: [AgentConfiguration]

    /// 加载状态
    var isLoading: Bool

    /// 错误信息
    var error: String?

    /// 刷新列表
    func refresh() async

    /// 添加 Agent
    func addAgent(_ agent: AgentConfiguration) async

    /// 删除 Agent
    func deleteAgent(_ agent: AgentConfiguration) async

    /// 连接 Agent
    func connect(agent: AgentConfiguration) async

    /// 断开 Agent
    func disconnect(agent: AgentConfiguration) async
}
```

## 契约 7: ChatViewModel

**职责**: 聊天界面的 UI 状态管理

**协议定义**:

```swift
@Observable
@MainActor
class ChatViewModel {
    /// 当前会话
    var session: Session?

    /// 消息列表
    var messages: [Message]

    /// 当前输入文本
    var inputText: String

    /// 是否正在处理
    var isProcessing: Bool

    /// 发送消息
    func send() async

    /// 取消当前请求
    func cancel() async

    /// 清空输入
    func clearInput()

    /// 加载历史消息
    func loadHistory() async
}
```

## 错误处理契约

所有模块必须遵循统一的错误处理契约：

```swift
/// 应用错误类型
enum AgentClientError: Error, LocalizedError {
    case agentNotFound
    case connectionFailed(underlying: Error)
    case authenticationFailed
    case sessionCreationFailed
    case promptFailed(underlying: Error)
    case permissionDenied
    case dataCorrupted

    var errorDescription: String? {
        // 返回用户友好的中文消息
    }
}
```

## 数据流契约

### 用户发送消息流程

```
1. ChatViewModel.send()
   ↓
2. 验证输入，创建 Message (status: .pending)
   ↓
3. MessageRepository.add(message)
   ↓
4. ACPClientService.sendPrompt(text:, to:)
   ↓
5. 订阅 AsyncStream<SessionUpdate>
   ↓
6. 收到更新 → MessageRepository.updateStatus()
   ↓
7. ViewModel 自动刷新 UI (@Observable)
```

### Agent 连接流程

```
1. AgentListViewModel.connect(agent:)
   ↓
2. ACPClientService.connect(agent:)
   ↓
3. swift-acp Client.launch()
   ↓
4. Client.initialize()
   ↓
5. 返回 AgentInfo → 更新 AgentConfiguration.lastUsedAt
   ↓
6. ViewModel 刷新连接状态
```

## 测试契约

所有服务协议必须支持依赖注入，以便进行单元测试：

```swift
// 示例：测试用 Mock 实现
struct MockACPClientService: ACPClientServiceProtocol {
    var connectCalled: Bool = false
    var mockConnectionState: ConnectionState = .disconnected

    func connect(agent: AgentConfiguration) async throws {
        connectCalled = true
    }

    // ... 其他方法
}

// ViewModel 测试
@MainActor
func testAgentListViewModel() async {
    let mockService = MockACPClientService()
    let viewModel = AgentListViewModel(
        clientService: mockService,
        repository: mockRepository
    )

    await viewModel.connect(agent: testAgent)

    XCTAssertTrue(mockService.connectCalled)
}
```
