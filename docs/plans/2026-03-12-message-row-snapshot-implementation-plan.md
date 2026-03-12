# Message Row Snapshot Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move expensive message parsing and flow-presentation work out of row view bodies by introducing stable per-row snapshots and a list-level snapshot builder that can reuse unchanged rows while only recomputing the streaming tail.

**Architecture:** Keep this as a presentation-layer refactor. Do not change `Message`, `ToolCall`, `AgentRound`, or persisted payload formats. Introduce `MessageRowSnapshot` as the single input to `MessageBubbleView`, promote user/agent heavy derivation into pure snapshot builders, and let `ChatView` maintain a stable list snapshot that reuses previous row projections when a message’s visible inputs have not changed. Preserve the existing execution-order-first agent UI direction and keep `MarkdownMessageView` incremental parsing as-is.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `UserMessageTextParser`, `UserMessagePresentation`, `AgentMessageFlowPresentation`, `MarkdownMessageView`, and chat list rendering in `ChatView`.

---

## 1. 实施原则

- 这是一次渲染层重构，不是持久化改造。不要给 `Message` 增字段，不做 schema migration。
- 优先把“每次 body 刷新都会重算”的逻辑收敛成纯快照，再让 view 只做条件渲染和本地交互状态。
- 先保行为，再提性能。第一阶段不要顺手改 UI 文案、卡片层级或工具详情交互。
- `MarkdownMessageView` 已有增量 parser，不要把 markdown block 预解析塞进 row snapshot；snapshot 只负责决定传给它的稳定文本。
- 列表级 builder 必须支持“前一版 snapshot 输入不变则整行复用”，否则只是在别处重算，达不到 streaming 优化目标。

## 2. 当前问题定位

- `MessageBubbleView` 里仍有多个计算型属性直接依赖 `message`：`agentParsedContent`、`userParsedContent`、`userPresentation`、`editableUserText`。
- `AgentMessageStepFlowView` 也在 view 里做 `AgentMessageFlowPresentation.snapshot(for:)` 和 `toolLookup` 组装。
- `ChatView+MessageList` 直接 `ForEach(allMessages)`，每次流式更新最后一条时，列表层没有稳定投影边界，其他行也会跟着重新求值其 view 内部计算属性。
- 现有 `UserMessageTextParser`、`UserMessagePresentation`、`AgentMessageFlowPresentation` 已经是纯推导逻辑，但它们被挂在 row view 内调用，缓存和复用边界放错了位置。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageRowSnapshotTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListSnapshotBuilderTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageStepFlowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

## 4. Snapshot 设计约束

### MessageRowSnapshot

建议用 `struct`，只承载 row 渲染所需的稳定投影，避免把解析逻辑继续埋在 view 中。最小字段建议如下：

```swift
struct MessageRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let senderName: String
    let editableUserText: String?
    let user: UserRowSnapshot?
    let agent: AgentRowSnapshot?
}

struct UserRowSnapshot: Equatable {
    let bodyText: String
    let presentation: UserMessagePresentation
}

struct AgentRowSnapshot: Equatable {
    let attachments: MessageAttachmentSnapshot
    let flow: AgentMessageFlowSnapshot
}

struct MessageAttachmentSnapshot: Equatable {
    let images: [String]
    let pdfs: [String]
    let others: [String]
}
```

注意：

- `senderName`、`editableUserText`、`attachments` 都应该在 snapshot 阶段决定，避免 `MessageBubbleView` 自己再从 `message` 推导。
- 不要求 snapshot 和 SwiftData 模型彻底隔离。工具详情视图仍可通过 `toolCallID -> ToolCall` 查回实时模型，但 lookup 必须由 snapshot/presentation 层一次性准备好。
- `AgentMessageFlowSnapshot` 需要升级为“view 可直接消费”的结构，至少把当前 `toolLookup` 的组装从 `AgentMessageStepFlowView` 移出去。

### ChatMessageListSnapshotBuilder

建议 builder 维护一套保守的输入指纹，至少覆盖：

- `workspaceRoot`
- `message.id`
- `message.direction`
- `message.status`
- `message.timestamp`
- `message.textContent`
- `message.errorMessage`
- `agentRounds` 的可见内容
- `toolCalls` 的可见内容

原则是“宁可多重建，不可漏重建”。任何无法确定是否影响 UI 的字段变化，都算指纹变化。

## 5. 任务拆解

### Task 1: 先用测试锁定 row-level 投影边界

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageRowSnapshotTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: 写失败测试，固定 user row snapshot 契约**

覆盖以下行为：

- user message snapshot 直接产出 `editableUserText`
- user row snapshot 内已经包含 `UserMessagePresentation`
- 空 `workspaceRoot` 时不生成 mention token，但仍保留正文与附件分组

测试示例：

```swift
@Test func userRowSnapshotPrecomputesEditableTextAndPresentation() async throws {
    let message = Message.userFixture(text: "请查看 /tmp/ws/agentGui/Views/MessageBubbleView.swift")

    let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: "/tmp/ws")

    #expect(snapshot.user != nil)
    #expect(snapshot.editableUserText == snapshot.user?.bodyText)
    #expect(snapshot.user?.presentation.inlineItems.isEmpty == false)
}
```

**Step 2: 写失败测试，固定 agent flow snapshot 不再依赖 view 内 lookup 组装**

补充 `AgentMessageFlowPresentationTests`，要求 snapshot 本身能够提供 tool lookup 或等价访问方式，`AgentMessageStepFlowView` 不再拥有 `makeToolLookup(for:)`。

**Step 3: 运行 focused tests 确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: FAIL，因为 row snapshot 类型和 flow snapshot 新契约还不存在。

**Step 4: 写最小实现通过测试**

新增 `MessageRowSnapshot.make(for:workspaceRoot:)` 的最小版本，并让 `AgentMessageFlowSnapshot` 附带 view 所需的 tool lookup 数据。

**Step 5: 再跑 focused tests**

Run 同 Step 3。

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/ViewModels/MessageRowSnapshot.swift agentGuiTests/MessageRowSnapshotTests.swift agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "test: lock message row snapshot contracts"
```

### Task 2: 把 AgentMessageStepFlowView 改成纯 snapshot 渲染器

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageStepFlowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: 写失败测试，禁止 view 自己重建 snapshot**

新增测试断言：

- `AgentMessageStepFlowView` 初始化参数改为 `snapshot`
- `AgentMessageFlowSnapshot` 本身持有渲染子步骤所需 lookup，或者暴露 `toolCall(for:)`

这里不必做 SwiftUI snapshot test，优先锁 API 形状和 presentation 行为。

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: FAIL，因为 `AgentMessageStepFlowView` 仍接收 `Message`。

**Step 3: 写最小实现**

重构方向：

- 在 `AgentMessageFlowSnapshot` 中加入 `toolCallsByID` 或等价查询接口
- 保留现有 `steps` 结构，不改 execution-order-first 展示顺序
- `AgentMessageStepFlowView` 只做 `ForEach(snapshot.steps)` 和轻量 switch
- 删除 view 内 `snapshot` 计算属性与 `makeToolLookup(for:)`

如需要兼顾 `Equatable`，可以把 lookup 存成有序数组加 helper，而不是直接把 `[UUID: ToolCall]` 放进等值比较；不要为了 `Equatable` 把 view 重新绑回 `Message`。

**Step 4: 再跑测试确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGui/Views/AgentMessageStepFlowView.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "refactor: make agent step flow render from snapshot"
```

### Task 3: 让 MessageBubbleView 只消费 MessageRowSnapshot

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MessageRowSnapshotTests.swift`

**Step 1: 写失败测试，固定 row view 输入边界**

新增测试覆盖：

- `MessageBubbleView` 不再暴露 `message + workspaceRoot` 双输入来驱动重计算
- user bubble 纯消费 `snapshot.user.presentation`
- agent bubble 纯消费 `snapshot.agent.flow`

如果现阶段不方便直接做 view 单测，就把 API 变更写成编译级约束，确保 `MessageBubbleView` 初始化参数只接受 `snapshot` 加 action closures。

**Step 2: 运行测试或先编译确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: FAIL，因为调用点还没迁移。

**Step 3: 写最小实现**

具体改法：

- 删除 `MessageBubbleView` 内的 `ParsedContent`、`agentParsedContent`、`userParsedContent`、`userPresentation`、`editableUserText`
- `senderName` 改为从 snapshot 读取
- `userBubble` 使用 `snapshot.user.presentation` 和 `snapshot.user.bodyText`
- `agentCardContent` 使用 `snapshot.agent.flow` 和 `snapshot.agent.attachments`
- 保留 hover、editing、sheet 等纯交互状态在 view 内部

**Step 4: 编译并跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/MessageBubbleView.swift agentGui/ViewModels/MessageRowSnapshot.swift agentGuiTests/MessageRowSnapshotTests.swift
git commit -m "refactor: move message bubble derivation into row snapshots"
```

### Task 4: 引入 ChatMessageListSnapshotBuilder，支持整行复用

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListSnapshotBuilderTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`

**Step 1: 写失败测试，固定 builder 的复用语义**

覆盖以下行为：

- 首次构建时，为每条消息生成 `MessageRowSnapshot`
- 只有最后一条 streaming 消息文本变化时，前面未变消息应复用上一轮 snapshot
- `workspaceRoot` 变化时，user rows 需要重建，纯 agent rows 可按需重建或整体保守重建
- 某条消息的 tool call/status 变化时，仅该行重建

建议通过对象包装或 debug fingerprint 暴露来验证“复用”，不要只测数组值相等。可以引入轻量缓存条目：

```swift
struct CachedMessageRowSnapshot {
    let fingerprint: MessageRowFingerprint
    let snapshot: MessageRowSnapshot
}
```

**Step 2: 运行 focused tests 确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests
```

Expected: FAIL，因为 builder 还不存在。

**Step 3: 写最小实现**

实现一个纯函数或无状态 builder API，例如：

```swift
enum ChatMessageListSnapshotBuilder {
    static func build(
        messages: [Message],
        workspaceRoot: String,
        previous: [UUID: CachedMessageRowSnapshot]
    ) -> ChatMessageListSnapshot
}
```

要求：

- builder 自己负责生成 fingerprint
- 指纹不变时直接复用旧 snapshot
- 输出同时包含按展示顺序排列的 rows 和下一轮可复用 cache

**Step 4: 再跑 tests 确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGuiTests/ChatMessageListSnapshotBuilderTests.swift agentGui/ViewModels/MessageRowSnapshot.swift
git commit -m "feat: add reusable chat message list snapshot builder"
```

### Task 5: 在 ChatView 集成稳定列表 snapshot，替换 ForEach(allMessages)

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListSnapshotBuilderTests.swift`

**Step 1: 写失败测试，固定列表层调用方式**

至少覆盖一个集成行为：当最后一条 agent message streaming 更新时，builder 返回的前序 rows 仍复用，列表调用点改为 `ForEach(messageListSnapshot.rows)`。

**Step 2: 运行测试或先编译确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: FAIL，因为 `ChatView+MessageList` 还直接遍历 `allMessages`。

**Step 3: 写最小实现**

集成建议：

- 在 `ChatView` 中新增 `@State private var messageListSnapshot = ChatMessageListSnapshot.empty`
- 在 `messagesArea` 生命周期中基于 `allMessages`、`effectiveWorkspaceRoot` 更新 snapshot
- `ChatView+MessageList` 改为 `ForEach(messageListSnapshot.rows)`
- action closures 仍基于 `row.id` 回查 `allMessages` 对应 `Message`，不要把整个 `Message` 再传回 row view

如果 `onChange` 监听 `allMessages` 不稳定，可构造一个轻量 `projectionInputsSignature` 来驱动重建，避免把 builder 再塞回 body 直接调用。

**Step 4: 运行 focused tests 和一次质量冒烟**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

然后运行已有任务：`Quality Smoke`

Expected: 所有 focused tests PASS；冒烟任务无新增回归。

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+MessageList.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift
git commit -m "refactor: render chat list from stable row snapshots"
```

## 6. 验收标准

- `MessageBubbleView` 和 `AgentMessageStepFlowView` 不再直接从 `Message` 做复杂解析和 presentation 组装。
- `MessageBubbleView` body 内不再出现 `UserMessageTextParser.parse`、`UserMessagePresentation.make`、`AgentMessageFlowPresentation.snapshot` 这类重计算入口。
- 列表层存在显式的 `Message -> MessageRowSnapshot` 投影边界。
- streaming 仅更新最后一条消息文本时，builder 可复用前序未变行的 snapshot。
- 现有用户消息 mention/directive 展示、agent chronological flow、subagent 卡片、tool detail 行为保持不变。

## 7. 风险与防错点

- `Message`、`ToolCall`、`AgentRound` 是 SwiftData `@Model` 引用类型，不能用引用相等当作“未变化”判断。必须显式做可见字段指纹。
- 如果把 `ToolCall` 直接塞进 `Equatable` snapshot，等值比较会很快失去意义。优先把 lookup 放到不参与等值比较的 cache 容器，或者通过查询接口隔离。
- `workspaceRoot` 变化会影响 mention tokenization，必须纳入 builder 输入。
- 不要顺手改 `MarkdownMessageView`；它自己的增量 parse 是另一层优化问题。
- 如果集成层使用 `ForEach(snapshot.rows)` 后 action 回查 `Message` 失败，要优先修复 row-to-model 映射，而不是把整模型重新塞回 snapshot。

## 8. 建议执行顺序

1. 先完成 Task 1 和 Task 2，确保单行 snapshot 输入边界稳定。
2. 再完成 Task 3，把 `MessageBubbleView` 彻底改成轻量渲染器。
3. 最后做 Task 4 和 Task 5，把 builder 和列表级复用接上。

Plan complete and saved to `docs/plans/2026-03-12-message-row-snapshot-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?