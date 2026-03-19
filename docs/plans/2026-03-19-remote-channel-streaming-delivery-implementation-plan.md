# Remote Channel 流式投递与会话绑定治理实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 基于现有 Remote Channel 技术方案，分阶段把远程渠道从“整轮完成后一次性发送最终结果”升级为“loop 过程中持续投递远端可见反馈”，并同时根治 `RemoteConversationBinding` / channel 投影资源在 `Session` 删除后的孤立与漂移问题。

**Architecture:** 复用现有 `AgentLoop` 流式事件与 `RemoteAgentOrchestrator` 主链路，引入 `RemoteTurnDeliveryCoordinator`、渠道级 `ChannelProjectionSession`、投影持久化模型，以及统一的 session 删除协调器。Feishu 首期按两类策略实现：非卡片增量追加发送，卡片单消息持续更新。

**Tech Stack:** Swift 6、SwiftData、SwiftUI、Foundation networking、现有 `ClaudeService` / `AgentLoop` / `FeishuClient` / `ChannelRuntimeBootstrap` / `PersistenceCoordinator`、Swift Testing。

**Depends On:** `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/remote-channel-streaming-delivery-and-session-integrity-2026-03-19.md`

---

## 0. 范围约束

- 本轮必须交付 Remote Channel 的增量远端可见反馈，不能继续只在 loop 完成后发最终文本。
- 本轮必须保留现有本地 ChatView 流式投影行为，不允许因远端投递改造破坏本地消息流。
- 首期只要求 Feishu 真正落地流式策略，其他渠道先落通用抽象，不实现具体 adapter。
- 首期 Feishu 非卡片按追加发送实现，不引入文本消息编辑主策略。
- 首期 Feishu 卡片按单张卡片反复更新实现，必须持久化 `message_id`。
- 本轮必须解决 `Session` 删除后 stale `RemoteConversationBinding` 污染路由的问题，不能只补 UI 删除入口。
- 本轮允许保留 `RemoteMessageReceipt`，但新增投影绑定与投递审计后，它不再承担唯一状态机职责。
- 本轮不处理跨设备已读同步、撤回同步、外部人工修改消息后的回流同步。
- 本轮不做“所有历史脏数据自动全量修复”，但必须在 router 和完整性检查层提供自愈与可观测能力。

## 1. 实施原则

- 先锁定事件面和 delivery runtime，再接 Feishu 渠道逻辑，不要先在 `RemoteAgentOrchestrator` 里直接堆 if/else。
- 先补 focused tests 覆盖增量投递、stale binding 自愈与删除治理，再做具体接线，避免改造完只能人工点飞书验证。
- 远端投递是 loop 的投影层，不是 loop 的主控制层；渠道 API 失败不能反向拖垮本地 agent 执行主链路。
- 把“逻辑投影绑定”和“投递历史”分开建模，避免单模型同时承担路由、锚点、审计和状态机四种职责。
- session 删除治理必须同时覆盖显式删除路径、router 运行时自愈和完整性检查三道防线。
- Feishu API 调用必须做节流和强制刷新点控制，禁止把 token 级 delta 直接映射成网络请求。

## 2. 当前代码落点

本计划直接依赖这些现有文件与能力：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookEmitter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHooks/StreamProjectionHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundDeliveryCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteMessageReceipt.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DataIntegrityChecker.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

已确认的现状：

- loop 期间已经存在 `didReceiveTextDelta` / `didReceiveThinkingDelta` 事件，但 `executeRemoteTurn` 使用 `.none`，Remote Channel 未接入。
- `RemoteAgentOrchestrator` 只在 `executor.execute(...)` 返回最终字符串后才调用 `OutboundDeliveryCoordinator.deliver`。
- `IMChannelAdapter` 当前只有无状态的 `send(_:)`，不适合承载一整轮 turn 的增量投递生命周期。
- `RemoteConversationBinding` 只存 `sessionID` 字符串，删除 `Session` 后不会清理。
- `DataIntegrityChecker` 目前不检查 stale binding、duplicate binding 或 orphan receipt。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionProjectionBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelProjectionDelivery.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/AgentLoopProjectionEvent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteTurnDeliveryCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelProjectionDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelProjectionSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteChannelProjectionHook.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuProjectionDriver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuProjectionSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteTurnDeliveryCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteChannelProjectionHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuProjectionSessionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDeletionCoordinatorTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteMessageReceipt.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IntegrityIssue.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundDeliveryCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundChannelMessage.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DataIntegrityChecker.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteAgentOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DataIntegrityCheckerTests.swift`

## 4. 关键架构决策

### 4.1 不在 `IMChannelAdapter.send` 上继续堆生命周期参数

`send(_:)` 保留为简单一次性发送能力，但 streaming delivery 必须新增会话级抽象。原因：

- 远端锚点、节流窗口、失败降级、本轮完成态都需要跨多次事件共享状态。
- append / update / finalize 是“一个投递会话的多个操作”，不是“一次 send 的不同模式”。

### 4.2 loop 侧增加远端投影面，而不是在 orchestrator 手搓轮询

Remote Channel 必须直接消费 loop 内部的 snapshot 事件，否则无法获得真正的低延迟。实现上首期采用新增 `RemoteChannelProjectionHook` 的保守方案，避免同时大改 `StreamProjectionHook` 与本地 UI 投影结构。

### 4.3 投影绑定与投递审计分离

建议引入两个模型：

- `SessionProjectionBinding`：保存某次远端 turn 在某渠道上的逻辑投影绑定、主 `message_id`、最新 `message_id` 和状态。
- `ChannelProjectionDelivery`：append-only 的投递操作日志，保存 create / append / update / finalize / fail 的历史。

这样可以避免把 `RemoteMessageReceipt` 演化成不可维护的多职责模型。

### 4.4 Session 删除治理必须有三道防线

三道防线缺一不可：

- 显式删除路径：`SessionDeletionCoordinator`
- 运行时入口自愈：`RemoteConversationRouter`
- 诊断面检查：`DataIntegrityChecker`

### 4.5 Feishu 策略首期固定为“双模式”

- `text` / `post`：按节流阈值做增量追加发送。
- `interactive`：首次创建卡片后，持续 PATCH 更新同一 `message_id`。

后续若要支持文本编辑，同样通过 Feishu projection session 内部策略切换完成，不反向污染通用层。

## 5. 阶段拆解

### Phase 1: 建立通用投递事件与 delivery runtime

目标：先把 loop 到 remote delivery 的通用事件面、协调器和 hook 结构建立起来，不直接碰持久化模型大改。

产出：

- `AgentLoopProjectionEvent`
- `RemoteTurnDeliveryCoordinator`
- `ChannelProjectionDriver` / `ChannelProjectionSession`
- `RemoteChannelProjectionHook`

验收标准：

- loop 流式过程中可以向一个 test delivery session 持续发送 snapshot。
- 本地 UI streaming 行为保持不变。
- 渠道错误不会让 `executeRemoteTurn` 直接失败。

### Phase 2: RemoteAgentOrchestrator 与 ClaudeService 接入远端投影

目标：让 remote turn 真正消费 delivery handle。

产出：

- `RemoteAgentExecuting.execute(...)` 增加 `deliveryHandle`
- `RemoteAgentOrchestrator` 在执行前创建 turn handle
- `ClaudeService.executeRemoteTurn` 接入远端投影 hook

验收标准：

- 远端 turn 在本地尚未完成时，delivery handle 已收到至少一条 text snapshot。
- 失败态会走 `deliveryHandle.fail(...)` 而不是静默丢失。

### Phase 3: Feishu projection session 落地

目标：把 Feishu 首期流式策略落到真实 driver / session。

产出：

- `FeishuProjectionDriver`
- `FeishuProjectionSession`
- `FeishuClient` 扩展：文本追加相关发送辅助、文本更新能力预留、卡片 PATCH 更新能力
- `FeishuChannelAdapter` 暴露 projection driver

验收标准：

- 非卡片模式会按阈值追加多条消息。
- 卡片模式只创建一条 primary message，后续只更新这条卡片。
- 发生 PATCH 失败时能记录失败并安全降级。

### Phase 4: 持久化模型与删除治理

目标：根治 stale bindings 与孤立投影资源。

产出：

- `SessionProjectionBinding`
- `ChannelProjectionDelivery`
- `RemoteConversationBinding` 改关系模型
- `SessionDeletionCoordinator`
- `RemoteConversationRouter` 自愈逻辑

验收标准：

- 删除 `Session` 后相关 binding / projection / delivery 不再残留。
- 历史 stale binding 会在 router 入口被自动清理。
- 相同远端会话不会因为旧 binding 指向已删 session 而持续生成新 session。

### Phase 5: 完整性检查、回归测试与启动接线

目标：把 channel 资源纳入可靠性视角，补齐 app schema 和回归测试。

产出：

- `IntegrityIssue` 新枚举项
- `DataIntegrityChecker` 新规则
- `agentGuiApp` schema 注册新增模型
- focused tests / integration tests

验收标准：

- 完整性检查能报告 stale / duplicate / orphan 的 channel 资源问题。
- app 启动不会因为 schema 漏注册导致模型不可用。

## 6. 详细任务拆解

### Task 1: 建立远端投递事件面与协调器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/AgentLoopProjectionEvent.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteTurnDeliveryCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelProjectionDriver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelProjectionSession.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteTurnDeliveryCoordinatorTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- 高频 text snapshot 会被节流，而不是每次都透传到底层 session。
- `finish(finalText:)` 会触发强制 flush。
- `fail(summary:)` 会触发最终失败投递，但不会抛回上层。
- coordinator 在没有可用 driver 时表现为 no-op，而不是让 remote turn 崩溃。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RemoteTurnDeliveryCoordinatorTests
```

Expected: FAIL，因为事件面和 coordinator 尚未实现。

**Step 3: Write the minimal implementation**

- 定义 `AgentLoopProjectionEvent`
- 实现 `RemoteTurnDeliveryCoordinator.beginTurn(...)`
- 实现内部节流与 final flush 逻辑
- 提供一个 no-op session 兜底

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

### Task 2: 把 remote delivery handle 接入 remote turn 主链路

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteAgentOrchestratorTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `RemoteAgentOrchestrator.handleInbound(...)` 会在执行前创建 delivery handle。
- `executor.execute(...)` 能拿到 `deliveryHandle`。
- 成功结束时仍返回最终文本，并继续持久化本地 `agentMessage`。
- 执行失败时会通过 handle 发送 failure summary。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RemoteAgentOrchestratorTests
```

Expected: FAIL，因为现有 executor 协议不接收 handle。

**Step 3: Write the minimal implementation**

- 扩展 `RemoteAgentExecuting`
- `RemoteAgentOrchestrator` 注入 `RemoteTurnDeliveryCoordinator`
- `ClaudeRemoteAgentExecutor` 把 handle 转成 loop 投影目标

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

### Task 3: 新增 RemoteChannelProjectionHook，把 loop snapshot 投递到 handle

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteChannelProjectionHook.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteChannelProjectionHookTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `didReceiveTextDelta` 会转换成 text snapshot 事件。
- `didReceiveThinkingDelta` 可选择性投递 thinking snapshot。
- forced projection 会强制 bypass threshold。
- 远端投影 target 为 `nil` 时，hook 为 no-op。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RemoteChannelProjectionHookTests
```

Expected: FAIL，因为 hook 尚未实现。

**Step 3: Write the minimal implementation**

- 在 hook context 或 runtime 上增加 remote delivery target
- 注册 `RemoteChannelProjectionHook`
- 把 text / thinking / completion / failure 映射成统一事件

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

### Task 4: 扩展 FeishuClient，补齐卡片更新与投影 driver

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuProjectionDriver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuProjectionSession.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuProjectionSessionTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- text 模式第一次 snapshot 发送首条消息，后续达阈值时发送增量追加。
- interactive 模式第一次发送返回 `message_id` 后，后续 snapshot 使用 PATCH 更新同一消息。
- `update_multi` 在卡片初发和更新时都被显式带上。
- PATCH 失败时会产生日志并降级，而不是让 session 崩溃。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/FeishuProjectionSessionTests
```

Expected: FAIL，因为 Feishu projection session 和 PATCH API 尚未存在。

**Step 3: Write the minimal implementation**

- 为 `FeishuClient` 增加 `updateTextMessage` 预留接口和 `updateInteractiveCard` 实现
- 实现 `FeishuProjectionDriver`
- 实现 `FeishuProjectionSession` 的 text append / card patch 两套策略
- `FeishuChannelAdapter` 增加创建 projection driver 的能力

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

### Task 5: 新增投影持久化模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionProjectionBinding.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelProjectionDelivery.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `SessionProjectionBinding` 能稳定保存主 `message_id`、最新 `message_id` 与状态。
- `ChannelProjectionDelivery` 能记录 create / append / update / finalize / fail。
- app schema 正确注册新增模型。

**Step 2: Run test to verify it fails**

建议复用或新增 focused model tests。

**Step 3: Write the minimal implementation**

- 实现两个 SwiftData 模型
- 在 app schema 注册
- 为 delivery coordinator / Feishu session 暴露写入接口

**Step 4: Run test to verify it passes**

运行对应 focused tests 并确认 PASS。

### Task 6: 把投影持久化接入 delivery coordinator / Feishu session

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteTurnDeliveryCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuProjectionSession.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundDeliveryCoordinator.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- 首次创建投影时生成一条 `SessionProjectionBinding`。
- 每次实际网络投递生成一条 `ChannelProjectionDelivery`。
- 完成和失败会更新 binding 状态。

**Step 2: Run test to verify it fails**

运行 focused delivery tests，预期 FAIL。

**Step 3: Write the minimal implementation**

- 在 beginTurn 时创建或复用 projection binding
- 在 Feishu session 真正 create / append / patch 时写 delivery log
- 在 finish / fail 时更新 binding 终态

**Step 4: Run test to verify it passes**

运行对应 tests 并确认 PASS。

### Task 7: 把 `RemoteConversationBinding` 改成真实关系模型，并补 router 自愈

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteConversationBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`

**Step 1: Write the failing tests**

新增覆盖：

- stale binding 指向空 session 时会被删除并新建正确 binding。
- duplicate binding 时会保留最新且 session 存活的一条。
- 正常 binding 仍能复用原 session。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RemoteConversationRouterTests
```

Expected: FAIL，因为现有 router 不做自愈。

**Step 3: Write the minimal implementation**

- 为 `RemoteConversationBinding` 增加 `session: Session?`
- `Session` 增加 inverse relationship
- router 清理 stale / duplicate binding
- 更新 binding 的 `updatedAt`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

### Task 8: 新增 SessionDeletionCoordinator，替换散落删除路径

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDeletionCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- 删除一个 session 会同时删除 conversation bindings、projection bindings、projection deliveries、相关 receipts。
- 批量删除 session 时不会留下 channel 资源孤儿。

**Step 2: Run test to verify it fails**

运行 `SessionDeletionCoordinatorTests`，预期 FAIL。

**Step 3: Write the minimal implementation**

- 实现删除协调器
- UI 删除路径改为统一调用 coordinator

**Step 4: Run test to verify it passes**

运行对应 tests 并确认 PASS。

### Task 9: 补齐完整性检查

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/IntegrityIssue.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DataIntegrityChecker.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/DataIntegrityCheckerTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- stale remote conversation binding 会被报告。
- duplicate binding 会被报告。
- orphan projection binding / delivery / receipt 会被报告。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/DataIntegrityCheckerTests
```

Expected: FAIL，因为现有 checker 不检查 channel 资源。

**Step 3: Write the minimal implementation**

- 扩展 `IntegrityIssue.Kind`
- 在 checker 中加入 channel 资源规则

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

## 7. 数据迁移与兼容策略

### 7.1 `RemoteConversationBinding` 关系改造

推荐策略：

- 保留现有 `sessionID` 一轮版本，新增 `session: Session?`
- 启动期做一次轻量关联回填：按 `sessionID` 找 `Session` 并写回 relationship
- router 新逻辑始终以 `session` relationship 为主，`sessionID` 只作历史回填辅助

等稳定后再决定是否去掉冗余 `sessionID`。

### 7.2 新增投影模型时的旧数据处理

- `SessionProjectionBinding` 与 `ChannelProjectionDelivery` 没有历史兼容负担，直接新增即可。
- 老的 `RemoteMessageReceipt` 保留，不做 destructive migration。
- 历史 stale binding 不做启动时全量修复脚本，优先依赖 router 自愈和完整性检查暴露。

## 8. 测试计划

### 8.1 Focused 单元测试

- `RemoteTurnDeliveryCoordinatorTests`
- `RemoteChannelProjectionHookTests`
- `FeishuProjectionSessionTests`
- `RemoteConversationRouterTests`
- `SessionDeletionCoordinatorTests`
- `DataIntegrityCheckerTests`

### 8.2 集成测试

建议新增一组集成场景：

- 远端 inbound 消息进入后，loop 尚未结束就已经产生至少一条 outbound delivery。
- Feishu text 模式长回复被拆成多次追加发送。
- Feishu interactive 模式只创建一条 primary card，后续只 patch 同一 `message_id`。
- 删除 session 后，同一 `externalConversationID` 再来消息不会被 stale binding 污染。

### 8.3 回归验证

- `RemoteAgentOrchestratorTests`
- `FeishuChannelAdapterTests`
- `OutboundDeliveryCoordinatorTests`
- 本地 chat streaming 相关现有测试

## 9. 人工验证清单

### 9.1 Feishu 文本模式

- 用户向机器人发消息后，飞书侧在 loop 尚未结束前能看到首条回复。
- 长回复会继续追加后续分段，而不是一直静默等待。
- 最终完成后本地 `Session` 中 agent message 为完整文本。

### 9.2 Feishu 卡片模式

- 首次可见输出时创建一张 card。
- 后续内容增长时 card 内容被更新，而不是反复新发卡片。
- 最终完成后 card 呈现完整结果。

### 9.3 Session 删除与恢复

- 删除远端 channel 生成的 session 后，数据库中不再残留对应 binding / projection / delivery。
- 同一飞书会话再次来消息时只创建一个新的干净 session，不出现重复绑定污染。

## 10. 风险与缓解

### 10.1 风险：远端投递频率过高导致 Feishu 限流

缓解：

- coordinator 层统一节流
- 强制 flush 只在 round 边界、完成、失败时触发
- PATCH / append 失败时限制重试次数

### 10.2 风险：卡片 patch 失败导致远端体验断裂

缓解：

- 失败写 delivery log
- 可降级补发一条文本摘要
- 不阻断本地 loop 主链路

### 10.3 风险：关系模型改造引发历史数据兼容问题

缓解：

- 先保留 `sessionID` 冗余字段
- 启动时做轻量回填
- router 继续做防御式自愈

### 10.4 风险：删除路径只改了一部分 UI

缓解：

- 所有 session 删除操作统一收口到 `SessionDeletionCoordinator`
- 搜索并替换散落的 `modelContext.delete(session)`

## 11. 推荐提交顺序

建议按以下提交粒度推进：

1. `feat: add remote channel projection events and delivery coordinator`
2. `feat: wire remote delivery handle into orchestrator and agent loop`
3. `feat: add feishu streaming projection session`
4. `feat: persist channel projection bindings and delivery logs`
5. `feat: heal remote conversation bindings and coordinate session deletion`
6. `test: extend integrity checks for remote channel resources`

## 12. 完成标准

满足以下条件才算本计划完成：

- Remote Channel 不再是 final-only delivery。
- Feishu 文本模式在 loop 期间可见增量追加。
- Feishu 卡片模式在 loop 期间可见同消息更新。
- session 删除后不会留下影响路由的 stale binding。
- 完整性检查能发现 channel 资源漂移。
- focused tests 覆盖事件投影、Feishu session、router 自愈、删除治理与完整性检查。

## 13. 最终建议

落地顺序上，优先把“远端可见增量反馈”做出来，再补“绑定和投影资源治理”。原因很直接：前者立刻改善用户体验，后者保证系统不会边跑边腐化。两者都不能省，但工程推进上应先解决用户最直接感知到的高延迟，再补稳态数据治理。