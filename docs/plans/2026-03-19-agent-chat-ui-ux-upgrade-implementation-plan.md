# Agent Chat UI/UX Upgrade Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将当前“执行步骤即对话正文”的 agent 消息改造成“结果叙事 + 运行舞台 + 审计轨迹”的三层聊天体验，并且不破坏现有消息快照缓存、流式更新与测试基线。

**Architecture:** 保留现有 `ChatView -> ChatMessageListSnapshotBuilder -> MessageRowSnapshot -> MessageBubbleView` 投影链，不做 SwiftData schema 改造。把 `AgentMessageFlowPresentation` 从单一 `steps` 序列升级为同时产出 `Execution Theater`、`Narrative Transcript`、`Artifact Shelf`、`Execution Digest`、`Audit Trace` 的语义投影，再让 `AgentMessageStepFlowView` 负责 live/settled/audit 三种展示模式切换。已有 `ThinkingBubbleView`、`ToolCallBubbleView`、`SubagentTaskCardView` 与 `SubagentTimelineView` 不直接删除，而是降级为 audit 或 detail 层复用，避免重写全部细节视图。

**Tech Stack:** Swift 6、SwiftUI、SwiftData、Foundation、Swift Testing、XCTest UI Tests、现有 `MessageRowSnapshot` / `ChatMessageListSnapshotBuilder` / `AgentMessageFlowPresentation` / `ToolCallRowPresentation` / `MarkdownMessageView`。

**Depends On:** [docs/technical-spec/2026-03-19-agent-chat-ui-ux-upgrade.md](../technical-spec/2026-03-19-agent-chat-ui-ux-upgrade.md)

---

## 0. Read This First

- 当前列表层已经有增量快照缓存，不要绕过 `ChatMessageListSnapshotBuilder` 直接在 `View.body` 里重新推导大对象。
- 当前 agent 行仍以 `AgentMessageFlowSnapshot.steps` 驱动，问题根源不是“没有动画”，而是投影模型仍把 runtime trace 当成 transcript。
- 本轮不改 `Message`、`ToolCall`、`AgentRound` 的持久化结构，不做 migration。
- 本轮先追求信息层级正确与回归安全，再做高级动画；任何动画都必须依附明确状态语义。
- 旧消息默认展示 settled 形态，audit 必须显式进入，不能继续默认把 thinking/tool/subagent 全部铺在首屏。

## 1. Scope Guardrails

- 不做新的后端事件协议；所有 UI 语义都从现有 `Message`、`ToolCall`、`AgentRound` 投影得出。
- 不把 `ThinkingBubbleView`、`ToolCallBubbleView`、`SubagentTaskCardView` 彻底删除；先把它们降级为 audit/detail 层组件。
- 不在本轮引入新的全局设置面板；`Compact / Standard / Developer` disclosure preset 可留作后续能力开关，先只保证默认模式合理。
- 不为“炫酷”新增难以测试的随机动画；所有 phase/card transition 都必须能通过稳定的 view state 和 accessibility hook 验证。
- 不顺手重写整个 `ChatView`；主改造点集中在 view-model projection、message row 视图组合和 UI 可观测性。

## 2. Relevant Existing Files

### 当前必须阅读的实现文件

- `agentGui/Views/ChatView+MessageList.swift:31-135`
- `agentGui/Views/MessageBubbleView.swift:8-272`
- `agentGui/Views/AgentMessageStepFlowView.swift:3-22`
- `agentGui/ViewModels/AgentMessageFlowPresentation.swift:3-218`
- `agentGui/ViewModels/MessageRowSnapshot.swift:1-85`
- `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift:15-193`
- `agentGui/Views/ThinkingBubbleView.swift:9-81`
- `agentGui/Views/ToolCallBubbleView.swift:124-320`
- `agentGui/Views/SubagentTaskCardView.swift:13-246`
- `agentGui/Views/SubagentTimelineView.swift:12-220`
- `agentGui/Views/AgentMessageResultBlockView.swift:3-27`
- `agentGui/Views/ToolCallDetailContentView.swift:27-220`

### 当前必须阅读的测试文件

- `agentGuiTests/AgentMessageFlowPresentationTests.swift:6-220`
- `agentGuiTests/MessageRowSnapshotTests.swift:6-80`
- `agentGuiTests/ChatMessageListSnapshotBuilderTests.swift:6-120`
- `agentGuiUITests/ChatFlowUITests.swift:3-30`

## 3. Target File Plan

### New Files

- `agentGui/ViewModels/AgentExecutionProjection.swift`
- `agentGui/Views/ExecutionPhaseRibbonView.swift`
- `agentGui/Views/ExecutionTheaterView.swift`
- `agentGui/Views/ArtifactShelfView.swift`
- `agentGui/Views/ExecutionDigestView.swift`
- `agentGui/Views/AuditTraceDisclosureView.swift`
- `agentGuiTests/AgentExecutionProjectionTests.swift`

### Modify Files

- `agentGui/ViewModels/AgentMessageFlowPresentation.swift:3-218`
- `agentGui/ViewModels/MessageRowSnapshot.swift:1-85`
- `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift:15-193`
- `agentGui/Views/AgentMessageStepFlowView.swift:3-22`
- `agentGui/Views/MessageBubbleView.swift:8-272`
- `agentGui/Views/ThinkingBubbleView.swift:9-81`
- `agentGui/Views/ToolCallBubbleView.swift:124-320`
- `agentGui/Views/SubagentTaskCardView.swift:13-246`
- `agentGui/Views/SubagentTimelineView.swift:12-220`
- `agentGui/Views/AgentMessageResultBlockView.swift:3-27`
- `agentGui/Views/ChatView+MessageList.swift:31-135`
- `agentGuiTests/AgentMessageFlowPresentationTests.swift:6-220`
- `agentGuiTests/MessageRowSnapshotTests.swift:6-80`
- `agentGuiTests/ChatMessageListSnapshotBuilderTests.swift:6-120`
- `agentGuiUITests/ChatFlowUITests.swift:3-30`

## 4. Implementation Order

先锁投影契约，再接 row snapshot，再接 settled/live 容器，再补 audit/detail 下沉，最后补 UI 可观测性和 smoke。不要先做动画；先让数据模型和层级正确。

---

### Task 1: 锁定三层投影模型契约

**Files:**
- Create: `agentGui/ViewModels/AgentExecutionProjection.swift`
- Create: `agentGuiTests/AgentExecutionProjectionTests.swift`
- Modify: `agentGui/ViewModels/AgentMessageFlowPresentation.swift:3-218`
- Modify: `agentGuiTests/AgentMessageFlowPresentationTests.swift:6-220`

**Step 1: Write the failing test**

先新增 `AgentExecutionProjectionTests.swift`，锁定 `ExecutionPhase`、`LiveTaskCardPresentation`、`ArtifactShelfPresentation`、`ExecutionDigestPresentation`、`AuditTracePresentation` 的最小契约。

```swift
@Test func projectionBuildsSettledTranscriptArtifactsAndDigest() async throws {
    let message = AgentMessageFlowFixture.makeChronologicalMessage()

    let projection = AgentExecutionProjection.make(for: message)

    #expect(projection.transcript.answerText == "完成调整")
    #expect(projection.artifacts.changedFiles.map(\.displayName) == ["MessageBubbleView.swift"])
    #expect(projection.digest.editedFileCount == 1)
    #expect(projection.audit.steps.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests`

Expected: FAIL，因为 `AgentExecutionProjection`、`transcript`、`artifacts`、`digest` 等类型和构建逻辑还不存在。

**Step 3: Write minimal projection types**

在 `AgentExecutionProjection.swift` 中先写最小语义模型，不要夹带视图状态：

```swift
struct AgentExecutionProjection: Equatable {
    let header: ExecutionHeaderPresentation
    let theater: ExecutionTheaterPresentation
    let transcript: NarrativeTranscriptPresentation
    let artifacts: ArtifactShelfPresentation
    let digest: ExecutionDigestPresentation
    let audit: AuditTracePresentation
}

enum ExecutionPhase: String, Equatable {
    case framing, inspecting, editing, running, verifying, delivering, blocked
}
```

**Step 4: Extend AgentMessageFlowPresentation to build the new projection**

先让 `AgentMessageFlowPresentation` 提供 `projection(for:)`，内部可继续复用现有 `steps` 生成逻辑，但必须把结果重新分发到五类 presentation，而不是只返回一个 `steps` 数组。

```swift
enum AgentMessageFlowPresentation {
    nonisolated static func projection(for message: Message) -> AgentExecutionProjection {
        let audit = snapshot(for: message)
        return AgentExecutionProjection.make(for: message, audit: audit)
    }
}
```

**Step 5: Re-run the focused tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests`

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/ViewModels/AgentExecutionProjection.swift agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGuiTests/AgentExecutionProjectionTests.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "test: lock agent execution projection contracts"
```

### Task 2: 把新投影接入 MessageRowSnapshot 和缓存链

**Files:**
- Modify: `agentGui/ViewModels/MessageRowSnapshot.swift:1-85`
- Modify: `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift:15-193`
- Modify: `agentGuiTests/MessageRowSnapshotTests.swift:6-80`
- Modify: `agentGuiTests/ChatMessageListSnapshotBuilderTests.swift:6-120`

**Step 1: Write the failing test**

先把 row snapshot 测试改成检查 agent 行不再只暴露 `flow.steps`，而是暴露完整的 `executionProjection`。

```swift
@Test func agentRowSnapshotPrecomputesExecutionProjection() async throws {
    let message = Message.agentFixture(text: "结果正文")

    let snapshot = MessageRowSnapshot.make(for: message, workspaceRoot: "")

    let agent = try #require(snapshot.agent)
    #expect(agent.execution.transcript.answerText == "结果正文")
    #expect(agent.execution.audit.steps.count == 1)
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests`

Expected: FAIL，因为 `AgentRowSnapshot` 仍只有 `attachments + flow + hasAgentRounds`。

**Step 3: Write minimal snapshot integration**

把 `AgentRowSnapshot` 升级为围绕 execution projection 的输入模型，仍然保留附件快照，避免把文件/媒体重新从 markdown 文本中解析多次。

```swift
struct AgentRowSnapshot: Equatable {
    let attachments: MessageAttachmentSnapshot
    let execution: AgentExecutionProjection
    let hasAgentRounds: Bool
}
```

**Step 4: Update fingerprint tests only if cache semantics actually changed**

不要重写 `MessageRowFingerprint`。先验证现有 `textContent`、`toolCalls`、`agentRounds` 指纹已足以覆盖新投影。如果发现 settle/live 状态切换未触发重建，再补最小字段，而不是预防性扩大 fingerprint。

```swift
@Test func builderRebuildsAgentRowWhenStatusChangesFromPendingToCompleted() async throws {
    // pending -> completed should rebuild because projection changes from live to settled
}
```

**Step 5: Re-run the focused tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests`

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/ViewModels/MessageRowSnapshot.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGuiTests/MessageRowSnapshotTests.swift agentGuiTests/ChatMessageListSnapshotBuilderTests.swift
git commit -m "refactor: project agent rows into execution snapshots"
```

### Task 3: 把 AgentMessageStepFlowView 重构为 live/settled/audit 容器

**Files:**
- Create: `agentGui/Views/ExecutionPhaseRibbonView.swift`
- Create: `agentGui/Views/ExecutionTheaterView.swift`
- Create: `agentGui/Views/ExecutionDigestView.swift`
- Create: `agentGui/Views/AuditTraceDisclosureView.swift`
- Modify: `agentGui/Views/AgentMessageStepFlowView.swift:3-22`
- Modify: `agentGui/Views/AgentMessageResultBlockView.swift:3-27`
- Modify: `agentGui/Views/MessageBubbleView.swift:113-177`

**Step 1: Write the failing test**

先在现有 presentation 测试里增加编译级约束，要求 `AgentMessageStepFlowView` 不再接收“只含 `steps` 的 flow snapshot”，而是接收完整 execution projection。

```swift
// 这里优先用编译失败驱动 API 迁移，不强求先做 SwiftUI snapshot test。
let view = AgentMessageStepFlowView(projection: projection)
_ = view.body
```

**Step 2: Run build to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build`

Expected: FAIL，因为 `AgentMessageStepFlowView(snapshot:)` 旧 API 仍在，调用点也还没迁移。

**Step 3: Write the new container views**

实现目标：

- `ExecutionPhaseRibbonView` 只渲染阶段带和当前 phase。
- `ExecutionTheaterView` 只渲染 live cards，不直接放长 thinking/tool output。
- `ExecutionDigestView` 只渲染一句摘要和风险提示。
- `AuditTraceDisclosureView` 负责折叠/展开 audit 轨迹。

```swift
struct AgentMessageStepFlowView: View {
    let projection: AgentExecutionProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if projection.header.isLive {
                ExecutionTheaterView(presentation: projection.theater)
            }
            AgentMessageResultBlockView(text: projection.transcript.answerText, isError: projection.transcript.isError)
            ExecutionDigestView(presentation: projection.digest)
            AuditTraceDisclosureView(presentation: projection.audit)
        }
    }
}
```

**Step 4: Wire MessageBubbleView to the new input**

`MessageBubbleView.agentCardContent` 改为消费 `snapshot.agent.execution`，不要再让 row view 自己判断 live/settled 信息架构。

**Step 5: Re-run build and focused tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests -only-testing:agentGuiTests/MessageRowSnapshotTests`

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/ExecutionPhaseRibbonView.swift agentGui/Views/ExecutionTheaterView.swift agentGui/Views/ExecutionDigestView.swift agentGui/Views/AuditTraceDisclosureView.swift agentGui/Views/AgentMessageStepFlowView.swift agentGui/Views/AgentMessageResultBlockView.swift agentGui/Views/MessageBubbleView.swift
git commit -m "refactor: split agent row into live settled and audit containers"
```

### Task 4: 落地 Artifact Shelf 和 settled transcript 信息层级

**Files:**
- Create: `agentGui/Views/ArtifactShelfView.swift`
- Modify: `agentGui/ViewModels/AgentExecutionProjection.swift`
- Modify: `agentGui/ViewModels/AgentMessageFlowPresentation.swift:3-218`
- Modify: `agentGui/Views/AgentMessageStepFlowView.swift:3-120`
- Modify: `agentGui/Views/MessageBubbleView.swift:160-177`
- Modify: `agentGuiTests/AgentExecutionProjectionTests.swift`

**Step 1: Write the failing test**

先给 artifact/digest 规则补测试，尤其是 changed files、referenced files、command summary、verification summary 的分桶规则。

```swift
@Test func projectionSeparatesChangedFilesReferencedFilesAndVerificationSummary() async throws {
    let message = AgentMessageFlowFixture.makeChronologicalMessage()

    let projection = AgentExecutionProjection.make(for: message)

    #expect(projection.artifacts.changedFiles.map(\.displayName) == ["MessageBubbleView.swift"])
    #expect(projection.artifacts.referencedFiles.map(\.displayName) == ["ChatView.swift"])
    #expect(projection.artifacts.commandSummaries.isEmpty)
    #expect(projection.digest.verificationSummary == nil)
}
```

**Step 2: Run the focused test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests`

Expected: FAIL，因为 projection 还没有 artifact shelf 分桶。

**Step 3: Implement Artifact Shelf presentation and view**

`ArtifactShelfPresentation` 最少包含：

```swift
struct ArtifactShelfPresentation: Equatable {
    let changedFiles: [ArtifactChipPresentation]
    let referencedFiles: [ArtifactChipPresentation]
    let citations: [ArtifactChipPresentation]
    let commandSummaries: [ArtifactSummaryLine]
    let testSummaries: [ArtifactSummaryLine]
}
```

`ArtifactShelfView` 只渲染结构化 chip/summary，不直接回放工具输出全文。

**Step 4: Place Artifact Shelf between result block and digest**

settled 结构固定为：`Answer Block -> Artifact Shelf -> Execution Digest -> Audit Disclosure`。不要把 digest 放到 answer 上面，也不要在 settled 模式继续默认渲染 tool/thinking 卡片。

**Step 5: Re-run focused tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/MessageRowSnapshotTests`

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/ArtifactShelfView.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGui/Views/AgentMessageStepFlowView.swift agentGui/Views/MessageBubbleView.swift agentGuiTests/AgentExecutionProjectionTests.swift
git commit -m "feat: add artifact shelf and settled transcript layout"
```

### Task 5: 把 thinking/tool/subagent 从正文层下沉到 live summary 和 audit detail

**Files:**
- Modify: `agentGui/Views/ThinkingBubbleView.swift:9-81`
- Modify: `agentGui/Views/ToolCallBubbleView.swift:124-320`
- Modify: `agentGui/Views/SubagentTaskCardView.swift:13-246`
- Modify: `agentGui/Views/SubagentTimelineView.swift:12-220`
- Modify: `agentGui/Views/ToolCallDetailContentView.swift:27-220`
- Modify: `agentGui/ViewModels/AgentExecutionProjection.swift`
- Modify: `agentGuiTests/AgentMessageFlowPresentationTests.swift:6-220`

**Step 1: Write the failing test**

先锁定两个最重要的 UX 约束：

- live 模式下只显示摘要卡，不显示长正文 trace。
- settled 模式下 audit 默认折叠，但展开后仍能看到旧 detail 组件。

```swift
@Test func liveProjectionSummarizesThinkingAndToolCallsInsteadOfRenderingRawBlocks() async throws {
    let message = AgentMessageFlowFixture.makeRunningCommandMessage()

    let projection = AgentExecutionProjection.make(for: message)

    #expect(projection.theater.cards.map(\.title).contains("Running xcodebuild -scheme agentGui"))
    #expect(projection.audit.steps.contains { if case .thinking = $0 { return true }; return false })
}
```

**Step 2: Run the focused tests to verify they fail**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests -only-testing:agentGuiTests/AgentExecutionProjectionTests`

Expected: FAIL，因为 live/audit 仍共用一套 step 输出。

**Step 3: Add explicit summary/detail modes to existing detail views**

不要复制一份新的 thinking/tool/subagent 组件。给现有组件补最小模式开关，让它们在 audit/detail 层复用，在 live 层只消费 summary presentation。

```swift
enum ToolCallRenderMode {
    case liveSummary
    case auditDetail
}

struct ToolCallBubbleView: View {
    let toolCall: ToolCall
    let rowPresentation: ToolCallRowPresentation
    let mode: ToolCallRenderMode
}
```

**Step 4: Keep raw trace only behind AuditTraceDisclosureView**

`SubagentTimelineView` 只能从 audit 展开入口进入；`ExecutionTheaterView` 里只显示 subagent contribution summary，不显示 round timeline。

**Step 5: Re-run focused tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests -only-testing:agentGuiTests/AgentExecutionProjectionTests`

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Views/ThinkingBubbleView.swift agentGui/Views/ToolCallBubbleView.swift agentGui/Views/SubagentTaskCardView.swift agentGui/Views/SubagentTimelineView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/ViewModels/AgentExecutionProjection.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "refactor: demote raw execution trace into audit detail layer"
```

### Task 6: 补 UI 可观测性、settle 行为和回归验证

**Files:**
- Modify: `agentGui/Views/ExecutionTheaterView.swift`
- Modify: `agentGui/Views/ArtifactShelfView.swift`
- Modify: `agentGui/Views/ExecutionDigestView.swift`
- Modify: `agentGui/Views/AuditTraceDisclosureView.swift`
- Modify: `agentGui/Views/ChatView+MessageList.swift:31-135`
- Modify: `agentGui/Views/MessageBubbleView.swift:8-272`
- Modify: `agentGuiUITests/ChatFlowUITests.swift:3-30`

**Step 1: Write the failing UI test**

扩展 `ChatFlowUITests`，至少覆盖两个最关键的用户路径：

- 执行中看到 phase ribbon / live task cards。
- 完成后看到 answer block / artifact shelf / digest，而 audit 默认折叠。

```swift
func testAgentMessageSettlesIntoTranscriptArtifactsAndDigest() throws {
    launchApp(arguments: [
        "-com.agentgui.test.chatProjectionFixture", "settledAgentDelivery"
    ])

    XCTAssertTrue(app.otherElements["chat.agentMessage.artifactShelf"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.otherElements["chat.agentMessage.executionDigest"].exists)
    XCTAssertFalse(app.outlines["chat.agentMessage.auditTrace"].exists)
}
```

**Step 2: Run the UI test to verify it fails**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatFlowUITests`

Expected: FAIL，因为新的 accessibility hooks 和 fixture mode 还不存在。

**Step 3: Add stable accessibility identifiers and settle hooks**

至少补这些标识：

- `chat.agentMessage.phaseRibbon`
- `chat.agentMessage.executionTheater`
- `chat.agentMessage.liveTaskCard.<id>`
- `chat.agentMessage.answerBlock`
- `chat.agentMessage.artifactShelf`
- `chat.agentMessage.executionDigest`
- `chat.agentMessage.auditDisclosure`

同时把 settle 动作做成明确状态切换，而不是纯 `withAnimation` 副作用。

**Step 4: Run the UI test and the existing unit tests**

Run: `xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatFlowUITests -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests`

Expected: PASS。

**Step 5: Run the smoke suite**

Run: `./scripts/run_quality_smoke.sh`

Expected: PASS。如果失败，只修复与聊天投影改造直接相关的回归，不扩散到无关模块。

**Step 6: Commit**

```bash
git add agentGui/Views/ExecutionTheaterView.swift agentGui/Views/ArtifactShelfView.swift agentGui/Views/ExecutionDigestView.swift agentGui/Views/AuditTraceDisclosureView.swift agentGui/Views/ChatView+MessageList.swift agentGui/Views/MessageBubbleView.swift agentGuiUITests/ChatFlowUITests.swift
git commit -m "test: cover agent chat live and settled projections"
```

## 5. Implementation Notes

### Projection rules

- `Execution Theater` 只展示当前阶段、活跃卡片、子代理贡献摘要、验证脉冲，不展示长原文。
- `Narrative Transcript` 只展示最终结果正文和必要错误信息。
- `Artifact Shelf` 只展示 changed files、referenced files、citations、command summaries、test summaries。
- `Execution Digest` 必须可从已知结构推导，不允许再调用 view 层统计。
- `Audit Trace` 保留现有 step 语义和 detail 组件，避免丢失工程可观测性。

### Phase mapping guidance

- `thinking` 且尚未进入工具阶段时优先映射到 `framing` 或 `inspecting`。
- `read/search/fetch` 优先映射到 `inspecting`。
- `edit` 优先映射到 `editing`。
- `execute` 根据命令语义和终端元数据映射到 `running` 或 `verifying`。
- `subagent` 不单独占据 transcript；在 live 层映射为 delegated capability card，在 digest 层映射为 contribution summary。
- `failed`、`awaiting approval`、`user takeover` 必须映射到 `blocked` 或显式 attention state。

### Testing guidance

- 单元测试优先锁投影模型，而不是做大而脆的 SwiftUI 截图测试。
- UI 测试只覆盖层级切换和关键标识，不要尝试断言动画帧。
- 如果 `Quality Smoke` 仍因为历史问题失败，必须记录具体失败点，并把本次变更相关性写清楚，不要静默忽略。

### Review checklist

- 没有在 `View.body` 内重新推导大型 projection。
- settled 形态首屏不再出现 thinking/tool/subagent 原始气泡。
- audit 展开后仍能访问旧 detail 信息。
- `ChatMessageListSnapshotBuilder` 仍能复用未变化行。
- 失败态和等待批准态比成功态更显眼，而不是被“美化掉”。

## 6. Suggested Command Order

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentExecutionProjectionTests -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MessageRowSnapshotTests -only-testing:agentGuiTests/ChatMessageListSnapshotBuilderTests
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/ChatFlowUITests
./scripts/run_quality_smoke.sh
```

## 7. Out of Scope Follow-Ups

- `Compact / Standard / Developer` disclosure preset。
- 更复杂的 `Subagent Constellation` 空间布局和高级动效。
- artifact chip 点击后的深层导航面板。
- 面向远程 channel 的消息投影复用。

Plan complete and saved to `docs/plans/2026-03-19-agent-chat-ui-ux-upgrade-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**