# 快速开始指南: AI Agent 客户端

**日期**: 2026-02-10
**功能**: AI Agent 客户端

## 概述

本指南帮助开发者快速理解 AI Agent 客户端项目的结构和开发流程。

## 前置要求

- macOS 26.0+
- Xcode 16.0+
- Swift 6.0+
- 已安装的 AI Agent（如 Claude Code CLI）

## 项目结构

```
agentGui/
├── App/                     # 应用入口
│   └── agentGuiApp.swift
├── Models/                  # SwiftData 模型
│   ├── AgentConfiguration.swift
│   ├── Session.swift
│   ├── Message.swift
│   ├── ToolCall.swift
│   ├── PermissionRequest.swift
│   └── AppSettings.swift
├── Services/                # 业务服务
│   ├── ACPClientService.swift       # ACP 客户端封装
│   ├── AgentLifecycleService.swift  # Agent 生命周期
│   ├── SessionManager.swift         # 会话管理
│   └── PermissionManager.swift      # 权限管理
├── Repositories/            # 数据访问
│   ├── AgentRepository.swift
│   ├── SessionRepository.swift
│   └── MessageRepository.swift
├── ViewModels/              # 视图模型
│   ├── AgentListViewModel.swift
│   ├── SessionViewModel.swift
│   ├── ChatViewModel.swift
│   └── SettingsViewModel.swift
├── Views/                   # SwiftUI 视图
│   ├── AgentListView.swift
│   ├── SessionListView.swift
│   ├── ChatView.swift
│   ├── PermissionDialog.swift
│   └── SettingsView.swift
└── Utilities/               # 工具类
    ├── ACPAdapters.swift
    └── Extensions.swift
```

## 快速开始

### 1. 克隆并打开项目

```bash
cd /path/to/agentGui
open agentGui.xcodeproj
```

### 2. 配置 Swift Package Dependencies

项目依赖 swift-acp，已在 `Package.resolved` 中配置：

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/wiedymi/swift-acp.git",
        branch: "main"
    )
]
```

### 3. 运行应用

按 `Cmd + R` 运行应用。首次启动会显示空的 Agent 列表。

### 4. 添加第一个 Agent

1. 点击 Agent 列表中的"添加"按钮
2. 填写 Agent 配置：
   - 名称: `Claude Code`
   - 类型: `claude-code`
   - 连接类型: `本地进程 (stdio)`
   - 可执行路径: `/usr/local/bin/claude`
3. 点击"保存"

### 5. 连接 Agent 并创建会话

1. 选择已添加的 Agent，点击"连接"
2. 连接成功后，点击"新建会话"
3. 选择工作目录
4. 在聊天框输入消息并发送

## 核心概念

### ACP 通信流程

```
应用启动
  ↓
ACPClientService 初始化
  ↓
Client.launch(agentPath)  // 启动 Agent 进程
  ↓
Client.initialize()       // 握手，交换能力
  ↓
Client.newSession()       // 创建会话
  ↓
Client.sendPrompt()       // 发送消息
  ↓
AsyncStream<Notification> // 接收流式更新
```

### 数据流

```
View (SwiftUI)
  ↓ @Observable
ViewModel (@MainActor)
  ↓ async/await
Service (Actor)
  ↓
SwiftData Model
```

## 开发指南

### 添加新的 Agent 类型

1. 在 `AgentType.swift` 中添加新的枚举值：

```swift
enum AgentType: String, Codable {
    case claudeCode = "claude-code"
    case openCode = "opencode"
    case myNewAgent = "my-new-agent"  // 新增
}
```

2. 在 `AgentListView.swift` 中添加对应的图标和默认参数

### 添加新的消息类型

1. 更新 `ContentType.swift` 枚举
2. 在 `ChatView.swift` 中添加对应的视图渲染逻辑
3. 在 `ACPAdapters.swift` 中添加 ACP 类型到应用类型的转换

### 自定义权限策略

修改 `PermissionManager.swift` 中的 `checkAutoApprove` 方法：

```swift
func checkAutoApprove(
    type: PermissionType,
    path: String
) -> Bool {
    // 自定义逻辑
    switch type {
    case .fileRead:
        return appSettings.autoApprovePolicy == .approveReads
    case .fileWrite:
        return appSettings.autoApprovePolicy == .approveAll
    default:
        return false
    }
}
```

## 调试技巧

### 启用 swift-acp 调试模式

```swift
// 在 ACPClientService 中
await client.enableDebugStream()

// 监听原始 JSON-RPC 消息
for await message in await client.debugMessages {
    let direction = message.direction == .outgoing ? "→" : "←"
    print("\(direction) \(message.jsonString ?? "")")
}
```

### 查看 SwiftData 数据库

```bash
# SQLite 数据库位置
~/Library/Containers/com.yourname.agentGui/Data/Library/Application\ Support/
```

### 常见问题

| 问题 | 解决方案 |
|-----|---------|
| Agent 启动失败 | 检查可执行路径是否正确，是否有执行权限 |
| 权限请求不显示 | 确保在 MainActor 上显示对话框 |
| 消息不显示 | 检查 @Observable 修饰符，确保在 @MainActor 更新 |
| 会话历史丢失 | 检查 SwiftData ModelContainer 配置 |

## 性能优化

### 消息列表优化

使用 `LazyVStack` 延迟加载消息：

```swift
LazyVStack(messages) { message in
    MessageRow(message: message)
}
```

### 数据库查询优化

为常用查询添加索引：

```swift
IndexDescription(Message.self, \Message.session?.sessionId)
```

### 内存管理

限制加载的消息数量：

```swift
fetchRecent(limit: 100)  // 而非 fetchAll()
```

## 测试

### 运行单元测试

```bash
# 测试所有
Cmd + U

# 测试特定文件
选择测试文件 → Cmd + U
```

### 运行 UI 测试

```bash
# 选择 agentGuiUITests scheme
Cmd + U
```

## 参考资源

- [swift-acp 文档](https://github.com/wiedymi/swift-acp)
- [ACP 协议规范](https://agentclientprotocol.com/)
- [SwiftData 文档](https://developer.apple.com/documentation/swiftdata)
- [SwiftUI HIG](https://developer.apple.com/design/human-interface-guidelines/macos)
