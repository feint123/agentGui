# 技术研究: AI Agent 客户端

**日期**: 2026-02-10
**功能**: AI Agent 客户端
**状态**: 完成

## 研究概要

本文档记录 AI Agent 客户端实现过程中的关键技术决策和研究结论。

## 决策 1: ACP SDK 集成方案

**决策**: 使用 swift-acp SDK 作为 ACP 协议的唯一实现方式

**理由**:
- swift-acp 是完整的 ACP 协议实现，支持客户端和服务端
- 已引入项目，无需额外集成工作
- 提供 Actor 并发安全模型，与 Swift 6 严格并发兼容
- 内置文件系统代理和终端代理，减少开发工作量

**SDK 组件选择**:
| 组件 | 用途 | 是否必需 |
|-----|-----|---------|
| ACPModel | 协议类型定义 | 必需 |
| ACP | 核心客户端运行时 | 必需 |
| ACPHTTP | WebSocket 传输 | P2（远程连接） |
| ACPRegistry | Agent 发现安装 | P3（注册表功能） |

**MVP 阶段**: 仅使用 ACPModel + ACP，支持本地 stdio 连接

## 决策 2: 并发模型设计

**决策**: 采用 Actor + AsyncStream 模式处理 ACP 通信

**理由**:
- swift-acp 的 Client 类型本身是 Actor，天然线程安全
- AsyncStream 适合处理流式会话更新（session/update 通知）
- Swift 6 严格并发要求避免数据竞争

**架构设计**:

```swift
// ACPClientService: Actor 封装 swift-acp Client
actor ACPClientService {
    private let client: Client
    private var activeSessions: [SessionID: SessionContext]

    func connect(agent: AgentConfiguration) async throws
    func createSession(workingDirectory: String) async throws -> Session
    func sendPrompt(_ content: String, to session: Session) async throws
    func disconnect() async
}

// SessionViewModel: @MainActor 处理 UI 更新
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isProcessing: Bool = false

    private let clientService: ACPClientService
    private var updateStream: Task<Void, Never>?
}
```

## 决策 3: 数据持久化策略

**决策**: SwiftData 用于所有持久化数据，内存缓存用于会话状态

**理由**:
- SwiftData 与 SwiftUI 深度集成，支持 @Query 自动更新
- ModelContainer 支持多模型共享，适合关系数据
- 会话期间的数据（Agent 连接状态、流式响应）保存在内存中

**数据分类**:

| 数据类型 | 存储方式 | 理由 |
|---------|---------|-----|
| Agent 配置 | SwiftData | 持久化，用户配置 |
| 会话元数据 | SwiftData | 持久化，历史记录 |
| 消息历史 | SwiftData | 持久化，大量数据 |
| 权限记录 | SwiftData | 持久化，审计需求 |
| 应用设置 | SwiftData | 持久化，偏好配置 |
| Agent 连接实例 | 内存 (Actor) | 临时，进程级 |
| 流式响应缓冲 | 内存 | 临时，实时更新 |

## 决策 4: UI 架构模式

**决策**: 采用标准的 macOS 三栏布局 + NavigationSplitView

**理由**:
- 符合 macOS 原生应用惯例（如 Mail、Xcode）
- NavigationSplitView 自适应布局，支持折叠/展开
- HIG 推荐的多面板导航模式

**布局设计**:

```
+------------------+-----------------------+------------------+
|   侧边栏          |   会话列表             |   聊天区域        |
|                  |                       |                  |
|  Agent 列表       |  Session 1            |  [用户] Hi       |
|  + Claude Code   |  Session 2            |  [Agent] Hello   |
|  + OpenCode      |  Session 3            |  [Tool] Read...  |
|                  |                       |                  |
|  [添加 Agent]    |  [新建会话]            |  [输入框]         |
+------------------+-----------------------+------------------+
```

## 决策 5: 错误处理策略

**决策**: 结构化错误类型 + 用户友好的错误消息

**错误分类**:

```swift
enum AgentClientError: LocalizedError {
    case agentNotFound(path: String)
    case agentLaunchFailed(reason: String)
    case connectionTimeout
    case authenticationFailed
    case sessionCreationFailed
    case promptFailed(reason: String)
    case permissionDenied

    var errorDescription: String? {
        // 返回中文友好消息
    }
}
```

**UI 显示**:
- 使用 Alert 显示错误
- 提供具体的解决建议
- 记录详细日志用于调试

## 决策 6: 权限对话框设计

**决策**: 模态对话框 + 异步等待模式

**理由**:
- macOS 标准权限请求方式
- 需要阻塞 Agent 操作等待用户决定
- 支持超时机制

**实现方案**:

```swift
actor PermissionManager {
    func requestPermission(_ request: PermissionRequest) async -> PermissionDecision {
        await withCheckedContinuation { continuation in
            // 在主线程显示对话框
            DispatchQueue.main.async {
                showPermissionDialog(request) { decision in
                    continuation.resume(returning: decision)
                }
            }
        }
    }
}
```

## 替代方案考虑

### ACP 协议自研 vs swift-acp

| 方案 | 优点 | 缺点 | 决策 |
|-----|-----|-----|-----|
| 自研协议 | 完全控制 | 开发成本高，需持续维护 | ❌ |
| swift-acp | 成熟稳定，持续维护 | 依赖外部项目 | ✅ |

### WebSocket vs stdio

| 方案 | 优点 | 缺点 | 优先级 |
|-----|-----|-----|-------|
| stdio | 简单，本地进程 | 仅本地 | P1 必需 |
| WebSocket | 远程连接 | 需额外库 | P2 可选 |

### 实时更新: AsyncStream vs Combine

| 方案 | 优点 | 缺点 | 决策 |
|-----|-----|-----|-----|
| AsyncStream | Swift 原生，与 async/await 配合 | 较新 | ✅ |
| Combine | 成熟， SwiftUI 支持 | 与 async/await 集成复杂 | ❌ |

## 技术风险与缓解

| 风险 | 影响 | 缓解措施 |
|-----|-----|---------|
| swift-acp 版本变更 | API 不兼容 | 锁定版本，关注更新 |
| Agent 进程崩溃 | 连接中断 | 监控进程状态，自动重连 |
| 大量消息历史 | 性能下降 | 分页加载，数据库索引 |
| 权限请求堆积 | UI 阻塞 | 队列管理，超时机制 |

## 性能考虑

1. **消息渲染**: 使用 LazyVStack 延迟加载历史消息
2. **流式更新**: 限制渲染频率，避免过度刷新
3. **数据库查询**: 为 Session.timestamp 和 Message.timestamp 创建索引
4. **内存管理**: 限制内存中缓存的消息数量

## 安全考虑

1. **Agent 路径验证**: 防止路径遍历攻击
2. **认证信息加密**: SwiftData 存储时使用 Keychain
3. **权限白名单**: 记住用户决定的权限请求需要安全存储
