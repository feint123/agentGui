# Feishu IM Channel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the first remote chat path for agentGui so a user can send messages to a Feishu application bot, have the local macOS app route those messages into an existing `Session`, run the current agent loop, and send the reply back to Feishu.

**Architecture:** Add a dedicated `Services/Channels` layer that separates channel adapter lifecycle, inbound normalization, conversation/session routing, dedup receipts, and outbound delivery from the existing `ClaudeService` and `AgentLoop`. Reuse the current `Session` / `Message` persistence model for actual conversation content, while storing external-channel metadata in separate SwiftData models so future IM tools can plug into the same runtime.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Foundation networking, existing `ClaudeService`, `WorkflowRuntime`, `AgentLoop`, `PersistenceCoordinator`, `agentGuiApp` bootstrap, and Swift Testing.

## 实施结果

2026-03-18 当前代码状态：

- 已完成通用渠道模型、去重、路由、远程编排、出站回执、飞书 payload/normalizer/credential store、adapter registry、渠道设置页和 app bootstrap 接线。
- 已补充对应的新增测试文件，覆盖模型、去重、路由、编排、投递、飞书归一化、adapter 生命周期、渠道设置、bootstrap 主链路，以及长连接协议层的 endpoint / frame codec / 分包 / ACK 测试。
- 已完成真实飞书网络客户端与长连接事件源首版实现，包含 `tenant_access_token` 获取、发送消息、回复消息、endpoint 建连、WebSocket 收包、protobuf `Frame`、`im.message.receive_v1` ACK、握手错误分类与首版自动重连。
- 已完成真实 `URLSessionWebSocketTask` 握手 response header 的基础运行时观测与设置页暴露。
- 尚未完成真实线上联调收口，因此当前状态是“协议主链路已实现，生产硬化未完成”。
- 本轮验证中，新增文件的静态诊断均通过；但仓库现有测试目标仍存在无关编译问题，导致 `xcodebuild test` 无法作为干净基线验证全部新增测试。

---

I'm using the writing-plans skill to create the implementation plan.

## 0. 范围约束

- 首期只支持飞书应用机器人单聊文本消息，不支持群聊 `@机器人`、卡片交互、附件收发、消息编辑同步。
- 首期只支持本地 `agentGui` 直连飞书事件，不建设独立公网网关服务。
- 首期只把远程消息映射到已有 `Session` / `Message`，不新建第二套聊天记录模型。
- 首期远程会话必须具备独立执行策略，默认比本地前台会话更严格，不直接继承全部工具权限。
- 所有飞书特化逻辑必须收敛在 `Services/Channels/Adapters/Feishu` 目录，不能扩散到 `ClaudeService` 核心循环中。
- 所有任务优先按 `@MainActor` + in-memory `ModelContainer` 写单元测试，避免先引入线程和网络噪音。

## 1. 实施原则

- 严格按 `@test-driven-development` 执行，先锁定模型、路由、去重、执行编排和设置持久化，再接真实飞书通信。
- 先完成“本地可模拟”的通用渠道框架，再落飞书 adapter，避免一开始把通用层写成飞书专用层。
- 远程渠道只负责“把外部消息变成本地会话输入”，实际 agent 执行继续复用现有 `ClaudeService` 与 `AgentLoop`。
- 外部渠道元数据要用独立模型表达，不把飞书字段塞进 `Session` / `Message`。
- 每个入站事件必须幂等，至少以 `externalMessageID` 作为稳定去重键。
- 每个出站消息必须可追踪，后续为失败重试、编辑、引用和多渠道扩展留出空间。

## 2. 当前代码落点

当前实现计划直接依赖这些现有文件和能力：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

已确认的现状和约束：

- 代码库当前没有 `Services/Channels` 目录，也没有外部 IM 渠道模型。
- `agentGuiApp` 已承担应用启动装配，适合作为渠道运行时的 bootstrap 入口。
- `ClaudeService+AgenticLoop.swift` 已提供现有 agent loop 入口，可以复用来执行远程消息，但目前没有“远程渠道会话”这一级编排封装。
- 设置页已经有独立导航项体系，适合新增一个“渠道”页来配置飞书凭证与连接状态。
- `AppSettings` 当前已承载多类功能开关，但飞书凭证不应直接以明文方式混入现有简单配置模型；首期需要先定义安全存储边界。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IMChannelKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteMessageReceipt.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteExecutionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/InboundChannelMessage.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundChannelMessage.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelMessagePresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelEventDeduplicator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundDeliveryCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuMessageNormalizer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuPayloadModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuCredentialStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/IMChannelModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelEventDeduplicatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteAgentOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OutboundDeliveryCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuMessageNormalizerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

## 4. 关键架构决策

### 4.1 先做通用渠道层，再做飞书适配器

不要一开始就写 `FeishuMessage -> Session -> ClaudeService` 的直连逻辑。先定义统一渠道协议和归一化模型，否则第二个渠道接入时会被迫重写核心层。

### 4.2 渠道元数据与聊天内容分离

`Session` / `Message` 继续只承载本地聊天内容；外部会话绑定、入站去重、出站回执进入独立模型：

- `ChannelAccountBinding`
- `RemoteConversationBinding`
- `RemoteMessageReceipt`

这样可以避免核心聊天模型被平台字段污染。

### 4.3 远程会话执行通过编排器复用现有 AgentLoop

不要在飞书 adapter 中直接调 `ClaudeService.runAgenticLoop(...)`。统一通过 `RemoteAgentOrchestrator` 完成：

- 本地消息落库
- Session 解析
- 执行策略读取
- ClaudeService 调用
- 结果回写
- 出站消息投递

这样后续 Telegram / Slack 也能复用同一执行路径。

### 4.4 首期凭证处理优先保证边界，不追求完美密钥中心

飞书 `app_id` / `app_secret` 首期可以通过 `FeishuCredentialStore` 封装到 Keychain；`AppSettings` 只保存开关、显示名和绑定引用，不保存明文密钥。不要把飞书密钥直接塞进 `AppSettings` 普通字符串字段。

## 5. 任务拆解

### Task 1: 建立渠道模型、远程绑定模型与执行策略值类型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IMChannelKind.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteMessageReceipt.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteExecutionPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/IMChannelModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing test**

新增测试覆盖：

- `IMChannelKind` 可编码解码，包含 `feishu` 预留未来渠道值。
- `RemoteExecutionPolicy` 默认值是只读、保守预算。
- `ChannelAccountBinding` 默认 `isEnabled == false`，且保留配置引用键。
- `RemoteConversationBinding` 可稳定表达 `channelKind + externalConversationID + sessionId`。
- `RemoteMessageReceipt` 可表达 `inbound` / `outbound` 和去重键。
- `agentGuiApp` 的 SwiftData schema 已包含新增模型。

测试示例：

```swift
@Test func remoteExecutionPolicyDefaultsToRestrictedMode() {
    let policy = RemoteExecutionPolicy()

    #expect(policy.allowFileWrite == false)
    #expect(policy.allowBash == false)
    #expect(policy.allowNetworkTools == false)
    #expect(policy.maxRounds == 8)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/IMChannelModelTests
```

Expected: FAIL，因为渠道模型与 schema 尚未存在。

**Step 3: Write the minimal implementation**

- 给 5 个模型补齐最小字段、初始化器和枚举。
- 在 `agentGuiApp` 的 `ModelContainer` 注册中加入新模型。
- 让 `RemoteExecutionPolicy` 的默认值与技术方案一致。

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/IMChannelKind.swift agentGui/Models/ChannelAccountBinding.swift agentGui/Models/RemoteConversationBinding.swift agentGui/Models/RemoteMessageReceipt.swift agentGui/Models/RemoteExecutionPolicy.swift agentGui/agentGuiApp.swift agentGuiTests/IMChannelModelTests.swift
git commit -m "feat: add IM channel persistence models"
```

### Task 2: 建立通用渠道协议、去重器和会话路由器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelConfiguration.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/InboundChannelMessage.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundChannelMessage.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelMessagePresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelEventDeduplicator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelEventDeduplicatorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 相同 `externalMessageID` 的入站事件只会消费一次。
- 同一外部单聊会话首次进入时自动创建 `Session` 与 `RemoteConversationBinding`。
- 已有绑定再次进入时会复用原 `Session`。
- 路由器支持按渠道类型隔离，避免不同平台碰撞相同会话 ID。

测试示例：

```swift
@Test func routerCreatesSessionForFirstRemoteConversation() throws {
    let harness = try RemoteConversationRouterHarness.make()
    let message = InboundChannelMessage(
        channelKind: .feishu,
        externalConversationID: "p2p-chat-1",
        externalMessageID: "msg-1",
        externalUserID: "ou_user_1",
        text: "你好",
        mentionsBot: false,
        rawPayload: "{}",
        receivedAt: .now
    )

    let session = try harness.router.resolveSession(for: message, modelContext: harness.context)

    #expect(session.title.contains("Feishu"))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ChannelEventDeduplicatorTests \
  -only-testing:agentGuiTests/RemoteConversationRouterTests
```

Expected: FAIL，因为通用渠道层尚未存在。

**Step 3: Write the minimal implementation**

- 定义统一渠道协议和入出站消息模型。
- 用 `RemoteMessageReceipt` 做最小去重判断。
- 路由器按 `channelKind + externalConversationID` 查找或创建本地 `Session` 绑定。

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/IMChannelAdapter.swift agentGui/Services/Channels/IMChannelConfiguration.swift agentGui/Services/Channels/InboundChannelMessage.swift agentGui/Services/Channels/OutboundChannelMessage.swift agentGui/Services/Channels/ChannelMessagePresentation.swift agentGui/Services/Channels/ChannelEventDeduplicator.swift agentGui/Services/Channels/RemoteConversationRouter.swift agentGuiTests/ChannelEventDeduplicatorTests.swift agentGuiTests/RemoteConversationRouterTests.swift
git commit -m "feat: add channel routing and dedup primitives"
```

### Task 3: 建立远程执行编排器和出站投递协调器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundDeliveryCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteAgentOrchestratorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/OutboundDeliveryCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 远程入站消息会被写入 `Message.userMessage(...)`。
- 编排器会调用现有 agent 执行路径，而不是自己拼接对话历史。
- agent 成功时会写入本地 agent message，并回发一条出站消息。
- agent 失败时会写入系统或错误消息，并回发简短失败摘要。
- 出站协调器会为发送成功的消息创建 `RemoteMessageReceipt`。

测试示例：

```swift
@Test func orchestratorPersistsInboundAndOutboundMessages() async throws {
    let harness = try RemoteAgentHarness.make()

    try await harness.orchestrator.handleInbound(
        .fixture(text: "总结这个仓库"),
        modelContext: harness.context
    )

    let messages = try harness.context.fetch(FetchDescriptor<Message>())
    #expect(messages.contains(where: { $0.direction == .user && $0.textContent == "总结这个仓库" }))
    #expect(messages.contains(where: { $0.direction == .agent }))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RemoteAgentOrchestratorTests \
  -only-testing:agentGuiTests/OutboundDeliveryCoordinatorTests
```

Expected: FAIL，因为远程执行编排器和出站协调器尚未存在。

**Step 3: Write the minimal implementation**

- 抽象一个最小 `RemoteAgentExecuting` 协议，测试里可用 fake 执行器。
- `RemoteAgentOrchestrator` 负责：落用户消息、解析 Session、调用执行器、落 agent 输出。
- `OutboundDeliveryCoordinator` 负责：调用 adapter.send、记录 outbound receipt。
- 只在必要处给 `ClaudeService+AgenticLoop.swift` 增加一个可复用入口，不改核心循环结构。

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/RemoteAgentOrchestrator.swift agentGui/Services/Channels/OutboundDeliveryCoordinator.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/RemoteAgentOrchestratorTests.swift agentGuiTests/OutboundDeliveryCoordinatorTests.swift
git commit -m "feat: add remote channel execution orchestration"
```

### Task 4: 建立飞书 payload、消息归一化器和凭证存储边界

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuPayloadModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuMessageNormalizer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuCredentialStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuMessageNormalizerTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 飞书单聊文本消息事件能被归一化为 `InboundChannelMessage`。
- 非文本消息或缺少关键信息的 payload 会被忽略或返回可诊断错误。
- normalizer 会从 payload 中正确提取 `chat_id`、`message_id`、`sender_id`、文本内容。
- 凭证存储对象能读写 `app_id` / `app_secret`，但不会把明文写进 `AppSettings`。

测试示例：

```swift
@Test func normalizerBuildsInboundMessageFromFeishuTextEvent() throws {
    let payload = FeishuEventFixtures.singleChatTextEvent()
    let message = try FeishuMessageNormalizer().normalize(payload)

    #expect(message.channelKind == .feishu)
    #expect(message.externalConversationID == "oc_test_chat")
    #expect(message.externalMessageID == "om_test_message")
    #expect(message.text == "你好")
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/FeishuMessageNormalizerTests
```

Expected: FAIL，因为飞书 payload 模型和 normalizer 尚未存在。

**Step 3: Write the minimal implementation**

- 只覆盖单聊文本消息事件所需的 payload 字段。
- 归一化器只支持首版需要的路径，不提前做群聊和卡片逻辑。
- 凭证存储先给出 Keychain 封装协议和最小实现，后续再扩展更强校验。

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuPayloadModels.swift agentGui/Services/Channels/Adapters/Feishu/FeishuMessageNormalizer.swift agentGui/Services/Channels/Adapters/Feishu/FeishuCredentialStore.swift agentGuiTests/FeishuMessageNormalizerTests.swift
git commit -m "feat: add Feishu payload normalization"
```

### Task 5: 建立飞书 client 和首版 adapter 生命周期

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- adapter 启动时读取渠道配置与飞书凭证。
- adapter 收到归一化消息后会交给上层处理器，而不是直接操作 `ClaudeService`。
- adapter 发送文本消息时会调用飞书发送接口。
- registry 可以注册、启动和停止飞书 adapter。

测试示例：

```swift
@Test func adapterForwardsInboundMessageToHandler() async throws {
    let harness = FeishuAdapterHarness.make()
    try await harness.adapter.start(configuration: harness.configuration)

    try await harness.client.emitInboundEvent(.singleChatText)

    #expect(harness.receivedMessages.count == 1)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/FeishuChannelAdapterTests
```

Expected: FAIL，因为飞书 client、adapter 和 registry 尚未存在。

**Step 3: Write the minimal implementation**

- `FeishuClient` 先抽成协议 + stub，真实网络实现只覆盖首版发送文本和接收单聊文本事件所需接口。
- `FeishuChannelAdapter` 负责生命周期、事件订阅、归一化和 `send(...)` 封装。
- `IMChannelRegistry` 管理 adapter 实例并暴露启动/停止入口。

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift agentGui/Services/Channels/IMChannelRegistry.swift agentGuiTests/FeishuChannelAdapterTests.swift
git commit -m "feat: add Feishu channel adapter runtime"
```

### Task 6: 加入设置模型、渠道设置页和凭证保存流程

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`

**Step 1: Write the failing tests**

新增测试覆盖：

- 设置页可以显示飞书渠道开关、显示名和连接状态。
- 保存操作会写入 `ChannelAccountBinding` 和凭证存储，而不是把明文 secret 写进 `AppSettings`。
- 修改渠道启用状态后，设置持久化成功。
- 新导航项“渠道”会正确出现在设置列表。

测试示例：

```swift
@Test func saveFeishuSettingsPersistsBindingAndCredentials() throws {
    let harness = try ChannelSettingsHarness.make()

    harness.viewModel.feishuEnabled = true
    harness.viewModel.feishuDisplayName = "我的飞书 Bot"
    harness.viewModel.feishuAppID = "cli_test"
    harness.viewModel.feishuAppSecret = "secret_test"

    try harness.viewModel.save()

    #expect(harness.credentialStore.savedAppID == "cli_test")
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ChannelSettingsViewModelTests
```

Expected: FAIL，因为渠道设置页和 view model 尚未存在。

**Step 3: Write the minimal implementation**

- 给设置导航新增 `channels` 项。
- `ChannelSettingsViewModel` 负责读写 `ChannelAccountBinding` 与凭证存储。
- `SettingsChannelsView` 首期只做飞书表单和连接状态展示，不做多渠道复杂管理 UI。

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChannelSettingsViewModel.swift agentGui/Views/Settings/SettingsChannelsView.swift agentGui/Models/AppSettings.swift agentGui/Views/Settings/SettingsNavigationItem.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsStore.swift agentGuiTests/ChannelSettingsViewModelTests.swift
git commit -m "feat: add channel settings UI"
```

### Task 7: 在 app bootstrap 中接入渠道运行时，打通端到端单聊链路

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`

**Step 1: Write the failing integration-style tests**

新增测试覆盖：

- 应用启动时，如果飞书渠道已启用，则注册并启动 adapter。
- 接收到一条飞书单聊文本消息后，能够完成“路由 -> 本地执行 -> 飞书回发”闭环。
- 关闭渠道后，adapter 会停止并释放状态。

测试示例：

```swift
@Test func bootstrapStartsEnabledFeishuChannel() async throws {
    let harness = try ChannelBootstrapHarness.make(feishuEnabled: true)

    try await harness.bootstrap.start()

    #expect(harness.registry.startedKinds == [.feishu])
}
```

**Step 2: Run tests to verify they fail**

Run targeted tests for the new bootstrap coverage.

Expected: FAIL，因为 app bootstrap 尚未接入渠道运行时。

**Step 3: Write the minimal implementation**

- 在 `agentGuiApp` 启动流程中装配 registry、router、orchestrator、delivery coordinator。
- 仅在飞书渠道启用时自动启动。
- 把需要的状态对象注入到设置页或 store，便于显示当前连接状态。

**Step 4: Run tests to verify they pass**

Run the same targeted tests and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/agentGuiApp.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Services/Channels/IMChannelRegistry.swift agentGui/Services/Channels/RemoteAgentOrchestrator.swift
git commit -m "feat: bootstrap Feishu IM channel runtime"
```

### Task 8: 回归测试与文档收口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-18-feishu-im-channel-architecture.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-18-feishu-im-channel-implementation-plan.md`

**Step 1: Run the focused test matrix**

至少执行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/IMChannelModelTests \
  -only-testing:agentGuiTests/ChannelEventDeduplicatorTests \
  -only-testing:agentGuiTests/RemoteConversationRouterTests \
  -only-testing:agentGuiTests/RemoteAgentOrchestratorTests \
  -only-testing:agentGuiTests/OutboundDeliveryCoordinatorTests \
  -only-testing:agentGuiTests/FeishuMessageNormalizerTests \
  -only-testing:agentGuiTests/FeishuChannelAdapterTests \
  -only-testing:agentGuiTests/ChannelSettingsViewModelTests
```

Expected: PASS.

**Step 2: Run the existing smoke tests likely affected by app bootstrap and message persistence**

建议额外执行：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ClaudeServiceMessagingTests \
  -only-testing:agentGuiTests/BackgroundAgentLoopAdapterTests
```

Expected: PASS.

**Step 3: Reconcile docs**

- 更新技术方案文档中的“实施状态”或“首版已落地能力”。
- 如果实现中调整了文件布局或命名，回写到本计划文档，保持计划与代码一致。

**Step 4: Commit**

```bash
git add docs/technical-spec/2026-03-18-feishu-im-channel-architecture.md docs/plans/2026-03-18-feishu-im-channel-implementation-plan.md
git commit -m "docs: finalize Feishu IM channel implementation plan"
```

## 6. 测试矩阵

实现期间至少保持下面这组测试常绿：

- `agentGuiTests/IMChannelModelTests`
- `agentGuiTests/ChannelEventDeduplicatorTests`
- `agentGuiTests/RemoteConversationRouterTests`
- `agentGuiTests/RemoteAgentOrchestratorTests`
- `agentGuiTests/OutboundDeliveryCoordinatorTests`
- `agentGuiTests/FeishuMessageNormalizerTests`
- `agentGuiTests/FeishuChannelAdapterTests`
- `agentGuiTests/ChannelSettingsViewModelTests`

回归时额外跑：

- `agentGuiTests/ClaudeServiceMessagingTests`
- `agentGuiTests/BackgroundAgentLoopAdapterTests`

## 7. 风险检查表

- 如果 `AppSettings` 被用作飞书明文密钥存储，停止并回退到凭证存储抽象。
- 如果 adapter 直接依赖 `ClaudeService` 而绕过 `RemoteAgentOrchestrator`，停止并重构。
- 如果路由器把平台字段写进 `Session` / `Message`，停止并改用独立绑定模型。
- 如果飞书首版实现开始引入群聊、卡片、附件等范围外能力，停止并回到 MVP。
- 如果入站没有基于 `externalMessageID` 做幂等，停止并先补去重。

## 8. 实施完成标准

满足以下条件才算首版完成：

- 设置页可以配置并启用一个飞书渠道。
- 本地 app 启动后可以启动飞书渠道运行时。
- 收到一条飞书单聊文本消息时，会创建或复用本地 `Session`。
- 该消息会进入现有 agent 执行流程并生成本地 `Message` 记录。
- agent 文本回复会成功回发到飞书。
- 同一条外部消息不会重复触发多次执行。
- 所有新增测试通过。