# Chat Message Background Projection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move chat message list snapshot construction onto a background computation path so large session switches and streaming updates no longer spend meaningful time rebuilding row projections on the main actor.

**Architecture:** Keep SwiftUI and SwiftData reads on the main actor, but immediately convert live `Message` graphs into sendable projection inputs and hand them to a background projection worker. Make the worker produce immutable snapshot results keyed by generation, let `ChatMessageListProjectionModel` cancel superseded work and only publish the latest accepted result, and split `workspaceRoot`-sensitive invalidation from the stable semantic fingerprint so directory changes only rebuild rows that actually depend on path parsing.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `MessageRowSnapshot`, `UserMessageTextParser`, `AgentMessageFlowPresentation`, and current chat list rendering in `ChatView`.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这次改造是消息列表投影层重构，不改 `Message`、`ToolCall`、`AgentRound` 的持久化 schema。
- 先锁并发和失效行为，再搬线程；不要先把代码丢到 detached task 里再补正确性。
- 主线程职责只保留：读取 SwiftData live models、生成 sendable 输入、发布最终 snapshot、驱动 SwiftUI state。
- 所有重计算都必须建立在值类型输入上；不要把 live `Message` 或 `ToolCall` 穿过 actor 边界。
- `workspaceRoot` 变化导致的失效面收敛，只做 Feature 6 范围内的必要拆分，不在本轮顺手做全面 fingerprint 瘦身。
- streaming 高频更新的正确性优先于“一次 build 极致快”；如果 generation/cancellation 不稳，后台化只会制造过期结果覆盖问题。
- 全部任务完成后，用 @requesting-code-review 做最终 review，重点看三点：后台构建是否真的脱离主线程、旧结果是否可能回写、目录变化是否还会整页失效。

## 2. 当前约束与设计决策

### 2.1 现有瓶颈必须先拆出 sendable 输入

当前 [agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift](agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift) 中的 `ChatMessageListProjectionTrigger`、`ChatMessageListSnapshotBuilder`、`MessageRowFingerprint` 都挂在 `@MainActor` 上，并且直接读取 live `Message` 图。后台化的前提不是“把 `build` 放进 `Task.detached`”，而是先定义一层 sendable request：

```swift
struct ChatMessageListBuildRequest: Sendable {
    let generation: UInt64
    let workspaceRoot: String
    let messages: [MessageRowBuildInput]
    let previousCache: [UUID: CachedMessageRowSnapshot]
}

struct MessageRowBuildInput: Sendable, Identifiable {
    let id: UUID
    let direction: MessageDirection
    let status: MessageStatus
    let timestamp: Date
    let textContent: String?
    let errorMessage: String?
    let directToolCalls: [ToolCallProjectionInput]
    let rounds: [AgentRoundProjectionInput]
}
```

这一步必须发生在主线程，因为 SwiftData model 不是 sendable；一旦 request 生成完成，后续 fingerprint 计算、cache 命中判断、snapshot build 都应成为纯函数或后台 actor 工作。

### 2.2 generation 接受规则必须比 cancellation 更强

仅取消旧任务不够，因为旧任务可能在取消信号到达前已经完成。`ChatMessageListProjectionModel` 需要维护单调递增的 `generation`，并且只接受 generation 与当前值一致的结果：

```swift
@MainActor
final class ChatMessageListProjectionModel {
    private var nextGeneration: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    func refresh(...) {
        nextGeneration &+= 1
        let generation = nextGeneration
        activeTask?.cancel()
        activeTask = Task { ... }
    }
}
```

要求实现同时满足：

- 旧任务收到取消后尽快停止。
- 即便旧任务已经产出结果，只要 generation 落后，也不能覆盖新 snapshot。
- 首屏 placeholder 逻辑只由“当前 generation 是否完成”决定，不能被已取消任务错误关闭。

### 2.3 `workspaceRoot` 只进入需要它的局部依赖签名

当前 `MessageRowFingerprint` 直接含有 `workspaceRoot`，导致目录变化时所有行都失效。Feature 6 先做最小收敛：

- 保留稳定语义指纹：消息方向、状态、文本、tool call/round 可见内容。
- 单独记录 `workspaceDependencyFingerprint`，只在 `UserMessageTextParser` 或附件/路径展示确实依赖工作目录时参与比较。
- cache entry 要显式标记该行是否依赖 `workspaceRoot`。

建议形状：

```swift
struct CachedMessageRowSnapshot: Sendable {
    let semanticFingerprint: MessageRowFingerprint
    let workspaceDependency: WorkspaceDependencyFingerprint?
    let snapshot: MessageRowSnapshot
}
```

这样目录切换时，agent 行以及不含路径上下文解析的 user 行可以继续复用旧 snapshot。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListProjectionWorker.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`

### 可选参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-12-message-row-snapshot-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-29-acp-runtime-state-refresh-requirements.md`

## 4. 任务拆解

### Task 1: 先用测试锁定后台化必须守住的行为

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift`

**Step 1: Write the failing test**

先把这 4 个行为写成失败测试：

- 旧 generation 的结果不能覆盖新 generation。
- `refresh` 连续调用时会取消前一轮构建。
- 目录变化时，不依赖 `workspaceRoot` 的行继续复用 cache。
- streaming 只变更最后一条消息时，不会重建前面所有行。

示例：

```swift
@Test
func staleGenerationResultIsDropped() async {
    let worker = ProjectionWorkerProbe()
    let model = ChatMessageListProjectionModel(worker: worker)

    await model.refresh(messages: worker.historyInputs, workspaceRoot: "/tmp/one")
    await model.refresh(messages: worker.streamingInputs, workspaceRoot: "/tmp/one")

    await worker.finishGeneration(1)
    #expect(model.snapshot.rows.map(\.id) == worker.streamingInputs.map(\.id))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 generation/cancellation 注入点、workspaceRoot 局部失效机制和并发测试支撑都还不存在。

**Step 3: Write minimal implementation**

这里只补测试夹具和 probe worker，不改生产逻辑：

```swift
protocol ChatMessageListProjectionWorking: Sendable {
    func build(request: ChatMessageListBuildRequest) async throws -> ChatMessageListBuildResult
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，测试能够稳定表达旧结果丢弃和局部复用要求。

**Step 5: Commit**

```bash
git add agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift
git commit -m "test: lock chat message projection concurrency behavior"
```

### Task 2: 抽出 sendable projection 输入和可复用 cache 结构

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MessageRowSnapshot.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`

**Step 1: Write the failing test**

增加针对值类型输入的测试，至少覆盖：

- live `Message` 被转换为 `MessageRowBuildInput` 后，builder 不再需要访问 SwiftData model。
- `CachedMessageRowSnapshot` 变成值类型后，未变更行仍能命中 cache。
- user 行会明确暴露是否依赖 `workspaceRoot`。

测试示例：

```swift
@Test
func buildRequestCapturesEverythingNeededForBackgroundProjection() {
    let session = Session.fixture(sessionId: "projection-input", title: "Projection Input")
    let message = Message.userMessage(text: "open Views/ChatView.swift", session: session)

    let request = ChatMessageListBuildRequest.make(
        messages: [message],
        workspaceRoot: "/tmp/ws",
        previousCache: [:],
        generation: 1
    )

    #expect(request.messages.count == 1)
    #expect(request.messages[0].id == message.id)
    #expect(request.messages[0].textContent == message.textContent)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 request DTO、sendable cache entry、workspace dependency 元数据尚未定义。

**Step 3: Write minimal implementation**

- 把 `CachedMessageRowSnapshot` 从 `@MainActor final class` 改成 `Sendable struct`。
- 新增 `ChatMessageListBuildRequest`、`MessageRowBuildInput`、`ToolCallProjectionInput`、`AgentRoundProjectionInput`。
- 增加 `WorkspaceDependencyFingerprint`，并让 `MessageRowSnapshot.make` 返回或附带“是否依赖 workspaceRoot”的元数据。

最小 API 形状：

```swift
struct WorkspaceDependencyFingerprint: Hashable, Sendable {
    let workspaceRoot: String
    let requiresWorkspaceRoot: Bool
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，后台 worker 所需输入和 cache 数据都已纯值化。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGui/ViewModels/MessageRowSnapshot.swift agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift
git commit -m "refactor: extract sendable chat projection inputs"
```

### Task 3: 引入后台 projection worker 和纯 build reducer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListProjectionWorker.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift`

**Step 1: Write the failing test**

新增 focused tests，要求：

- builder 可在非主线程运行。
- 上一版 cache 命中时不会重新生成旧 row snapshot。
- 只有最后一条消息变化时，前序行继续复用旧 snapshot。

```swift
@Test
func backgroundBuilderReusesUnchangedPrefixRows() async throws {
    let request = ChatMessageListBuildRequest.fixtureWithStreamingTail(messageCount: 500)
    let result = try await ChatMessageListProjectionWorker().build(request: request)

    #expect(result.rebuiltRowIDs == [request.messages.last?.id].compactMap { $0 })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为还没有后台 worker，也没有 result 级调试字段来断言重建集合。

**Step 3: Write minimal implementation**

- 新增 `ChatMessageListProjectionWorker` actor 或等价后台 worker。
- 让 `ChatMessageListSnapshotBuilder.build` 改成纯值函数，输入 `ChatMessageListBuildRequest`，输出 `ChatMessageListBuildResult`。
- 在 build 循环中显式检查 `Task.isCancelled`，避免大 history 构建白跑到底。

推荐 API：

```swift
actor ChatMessageListProjectionWorker: ChatMessageListProjectionWorking {
    func build(request: ChatMessageListBuildRequest) async throws -> ChatMessageListBuildResult
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，builder 脱离主线程且能复用未变更前缀。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListProjectionWorker.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests.swift
git commit -m "feat: add background chat message projection worker"
```

### Task 4: 让 projection model 负责 generation、cancellation 和结果接纳

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift`

**Step 1: Write the failing test**

补充 `ChatMessageListProjectionModelConcurrencyTests`，锁住下面 3 件事：

- 连续两次 `refresh` 会取消第一轮任务。
- 已取消 generation 完成后不会关闭当前 loading state。
- 第二轮更快完成时，snapshot 立即发布，不等待第一轮结束。

```swift
@Test
func latestGenerationPublishesImmediatelyEvenIfEarlierWorkIsStillRunning() async {
    let worker = ProjectionWorkerProbe()
    let model = ChatMessageListProjectionModel(worker: worker)

    await model.refresh(messages: worker.slowHistory, workspaceRoot: "/tmp/ws", showsLoadingPlaceholder: true)
    await model.refresh(messages: worker.fastIncremental, workspaceRoot: "/tmp/ws")
    await worker.finishGeneration(2)

    #expect(model.snapshot.rows.map(\.id) == worker.fastIncremental.map(\.id))
    #expect(model.isInitialLoadInFlight == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前 model 仍同步在主线程刷新，没有 generation 或 task 管理。

**Step 3: Write minimal implementation**

- 给 `ChatMessageListProjectionModel` 注入 worker。
- 加 `activeTask`、`nextGeneration`、`acceptedGeneration`。
- `refresh` 中先在主线程 capture request，再交给 worker；结果返回后只在 generation 匹配时更新 `snapshot`、`trigger`、`isInitialLoadInFlight`。

关键代码形状：

```swift
let request = ChatMessageListBuildRequest.make(..., generation: generation)
activeTask = Task {
    let result = try await worker.build(request: request)
    await MainActor.run {
        guard result.generation == self.nextGeneration else { return }
        self.snapshot = result.snapshot
    }
}
```

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，model 只发布最新 generation 的结果。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift
git commit -m "feat: guard chat projection updates by generation"
```

### Task 5: 把 ChatView 切到新的后台 projection 管线

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`

**Step 1: Write the failing test**

这一步以编译约束和已有测试回归为主，确保：

- `bootstrapSessionViewState` 首次加载仍会触发异步 projection refresh。
- `messagesArea` 继续只消费 `messageListProjectionModel.snapshot`。
- 不再在 view body 内同步构建 `currentMessageListProjectionTrigger` 作为重计算热点。

如果需要，给 `ChatMessageListProjectionRefreshCoordinatorTests` 增加一条回归测试：目录变化只会触发必要的 user row 更新。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL 或 build break，因为 view 层调用点仍依赖旧的同步 refresh 语义。

**Step 3: Write minimal implementation**

- 把 `currentMessageListProjectionTrigger` 的直接计算从 `messagesArea` 热路径移开。
- `refreshMessageListSnapshotForCurrentState` 只负责抓取当前 `allMessages` 和 `workspaceRoot`，然后调用 model 的后台 refresh。
- 保持滚动策略和 `messagesByID` lookup 不变，避免把本次重构扩散到 list 交互。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，聊天页保持现有行为，但 snapshot 构建不再同步压在主线程。

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+MessageList.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift
git commit -m "refactor: route chat view through background projection model"
```

### Task 6: 增加大消息量和高频增量回归测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionPerformanceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift`

**Step 1: Write the failing test**

新增两类场景：

- `largeHistorySwitchReturnsQuicklyAndPublishesLater`：模拟 1,000 到 5,000 条消息切会话时，`refresh` 调用本身快速返回，结果稍后发布。
- `streamingBurstRebuildsOnlyTailRows`：对最后一条消息做 20 到 50 次 text 增量更新，断言重建集合受控。

示例：

```swift
@Test
func largeHistoryRefreshReturnsQuicklyAndPublishesLater() async {
    let model = ChatMessageListProjectionModel(worker: .slowFixture)
    let messages = Message.fixtures(count: 2_000)
    let clock = ContinuousClock()
    let start = clock.now

    await model.refresh(messages: messages, workspaceRoot: "/tmp/ws", showsLoadingPlaceholder: true)
    let elapsed = start.duration(to: clock.now)

    #expect(elapsed < .milliseconds(50))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为当前没有性能 smoke fixtures，也没有暴露重建行集合或异步返回特征。

**Step 3: Write minimal implementation**

- 为 performance tests 提供 deterministic slow worker / burst fixture。
- 在 `ChatMessageListBuildResult` 中保留仅测试可见的 `rebuiltRowIDs` 或 `reusedRowCount`，用于断言不是整页重建。
- 如果需要，给 worker 增加分批 `Task.yield()` 策略，但只在测试证明确有长循环时再加；不要预先复杂化。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS，新增“大量消息 + 高频增量”场景稳定通过。

**Step 5: Commit**

```bash
git add agentGuiTests/ChatMessageListProjectionPerformanceTests.swift agentGuiTests/ChatMessageListProjectionModelConcurrencyTests.swift agentGui/ViewModels/ChatMessageListProjectionWorker.swift agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift
git commit -m "test: cover large history and streaming projection workloads"
```

## 5. 最终验证

按顺序执行以下验证，不要跳步：

1. Focused projection tests

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-final -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatMessageListProjectionRefreshCoordinatorTests -only-testing:agentGuiTests/ChatMessageListProjectionModelConcurrencyTests -only-testing:agentGuiTests/ChatMessageListProjectionPerformanceTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

2. Related chat regressions

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-message-projection-chat-regression -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests -only-testing:agentGuiTests/VoiceInputButtonPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，聊天页展示相关行为没有被投影改造连带破坏。

3. Optional broader smoke

```bash
./scripts/sample_quality_baseline.sh unit 5
```

Expected: baseline 无明显新增回归；如果时间过长，可作为合并前检查而不是每个 task 都跑。

## 6. 风险与回滚点

- 如果 sendable request 仍夹带 live model，引入后台 worker 后很容易踩 SwiftData 隔离错误；一旦发现，先回到 Task 2 收紧 DTO，而不是加 `@MainActor` 补丁。
- 如果 generation 只靠 `Task.cancel()` 而不做结果接纳校验，测试偶尔会过，但真实 streaming 下仍会被旧结果覆盖。
- 如果把 `workspaceRoot` 依赖切得过粗，Feature 6 仍会在目录变化时整页失效；但也不要在本轮试图重写所有 fingerprint 结构，避免和 Feature 7 混线。
- 如果为了测试可观测性引入过多 production debug 字段，记得限制为 internal/testing 可见范围，不要污染 UI 模型的长期 API。

## 7. 完成定义

- `ChatMessageListSnapshotBuilder` 的核心 build 路径不再要求 `@MainActor` 执行。
- `ChatMessageListProjectionModel.refresh` 具备 generation/cancellation 保护，并且只发布最新结果。
- `workspaceRoot` 变化不会默认导致所有 row cache 失效。
- 现有刷新测试保留通过，并新增“大量消息 + 高频增量” focused tests。
- 聊天页大 history 切换时，`refresh` 调用快速返回，最终 snapshot 异步发布。

Plan complete and saved to `docs/plans/2026-03-29-chat-message-background-projection-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**