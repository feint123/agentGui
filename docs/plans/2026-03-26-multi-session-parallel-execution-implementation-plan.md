# Multi-Session Parallel Execution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement session-scoped execution so built-in and ACP-backed conversations can continue running in parallel across session switches without tearing each other down or blocking the UI thread.

**Architecture:** Keep the current `ExecutionJob` / `ExecutionProjectionStore` / ACP session runtime assets, but split UI selection from execution ownership. Add session-scoped execution controllers and built-in interaction state, replace destructive ACP activation with non-destructive warmup, upgrade scheduler admission from runtime-scope locking to explicit capacity policy, and push slow runtime/transport work off `MainActor` while keeping projection publishing and user decisions on the main thread.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Swift Testing, existing execution orchestration stack (`ConversationExecutionOrchestrator`, `ExecutionScheduler`, `ExecutionProjectionStore`), built-in agent loop (`ClaudeService`, `AgentLoopToolExecutionCoordinatorBuilder`), ACP runtime stack (`ACPExternalExecutionProviderBase`, `ACPSessionRuntimeActor`, `ACPExternalAgentRuntimeClient`, `ACPConnection`).

---

## 1. 实施原则

- 严格按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过。
- 本次不是“加后台 badge”，而是执行 ownership 迁移；不要继续让 `WorkspaceState.selectedSession` 决定 runtime 生命周期。
- 内置 built-in 与 ACP 两条链路都要落到 session-scoped model；不要只修 ACP 或只修 built-in。
- 先锁行为，再替换实现；能复用现有 `ExecutionJob`、`ExecutionProjectionStore`、`SessionExecutionMailbox`、`ACPSessionRuntimeActor` 的地方不要重写。
- `MainActor` 只保留 UI 状态发布和用户交互决议；任何进程启动、transport IO、恢复、超时等待都不能继续停在主线程。
- 每完成一个任务就做小范围回归，避免把调度、恢复、UI 表现、审批交互混成一次大爆炸提交。
- 全部任务完成后，用 @requesting-code-review 做一次 review，重点检查：多 session 并行、ACP runtime 隔离、approval 路由、主线程慢路径。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ProviderExecutionCapacityPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionInteractionCenter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BuiltInSessionExecutionRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionInteractionCenterTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposerExecutionPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionSchedulingModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+AskUserQuestion.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`

### 重点测试文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceMessagingTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPConnectionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPLocalClientHandlerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPManagedClientRuntimeTests.swift`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-26-multi-session-parallel-execution-architecture.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-23-acp-runtime-session-scheduler-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-implementation-plan.md`

## 3. 任务顺序

1. 先锁定“切会话不停止执行”“审批和提问不串 session”“ACP runtime 不互相 teardown”的回归面。
2. 再扩展 execution projection 和 session controller，使 UI 先消费正确的执行态。
3. 然后把 built-in 的 `currentSession` / `pendingUserQuestion` / streaming 状态 session 化。
4. 接着替换 ACP activation 策略和 runtime client / transport 隔离约束。
5. 最后升级调度器容量模型，并收敛主线程边界、恢复逻辑和全量回归。

## 4. Task Breakdown

### Task 1: 锁定多会话并行的核心回归面

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceMessagingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

**Step 1: Write the failing test**

补 5 组 characterization tests，覆盖：

- built-in 会话 A 运行时，enqueue 会话 B 不应把 A 标成 finished。
- `WorkspaceState.selectedSession` 改变时，不应隐式调用 provider teardown。
- built-in approval / ask-user-question 必须按 `sessionID` 路由。
- ACP `prepareForActivation` 不得因为切到 B 而关闭 A 的 runtime。
- 两个 ACP session 并发时，一个 runtime client 关闭不能影响另一个 session。

```swift
@Test func switchingSelectedSessionDoesNotStopRunningJobProjection() async throws {
    let harness = try MultiSessionExecutionHarness.make()

    try await harness.startBuiltInJob(sessionID: "A")
    await harness.selectSession("B")

    let projection = await harness.projection(sessionID: "A")
    #expect(projection.runningJobID != nil)
    #expect(projection.isRunning)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with current single-session assumptions, destructive activation, or global built-in interaction state.

**Step 3: Write minimal implementation**

先只补测试 harness / spy provider / fixture helper，不改生产逻辑。

```swift
struct ProjectionAssertion {
    static func expectRunning(_ projection: SessionExecutionProjection) {
        #expect(projection.runningJobID != nil)
        #expect(projection.isRunning)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/ExecutionSchedulerTests.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift agentGuiTests/ClaudeServiceMessagingTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift
git commit -m "test: lock multi-session execution regressions"
```

### Task 2: 扩展 execution projection 并引入 session execution controller

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionController.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionControllerTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`

**Step 1: Write the failing test**

新增测试锁定三段式投影：

- `activityState` 区分 `idle / queued / running / blocked / finishing`
- `presentationState` 区分 `foreground / background`
- `needsAttention` 和 `attentionReason` 在阻塞输入时可见

```swift
@Test func controllerMarksBackgroundBlockedSessionAsNeedingAttention() async {
    let controller = SessionExecutionController(sessionID: "s1")

    await controller.recordBlocked(.userQuestion)

    let projection = await controller.projection
    #expect(projection.needsAttention)
    #expect(projection.attentionReason == .userQuestion)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/SessionExecutionControllerTests -only-testing:agentGuiTests/SessionExecutionRegistryTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with missing controller / registry and missing projection fields.

**Step 3: Write minimal implementation**

先把投影模型补齐，再让 controller 只负责单 session 的状态归并。

```swift
enum SessionExecutionActivityState: String, Equatable, Sendable {
    case idle, queued, running, blocked, finishing
}

enum SessionExecutionPresentationState: String, Equatable, Sendable {
    case foreground, background
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/SessionExecutionControllerTests -only-testing:agentGuiTests/SessionExecutionRegistryTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionProjection.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGui/Services/Execution/SessionExecutionController.swift agentGui/Services/Execution/SessionExecutionRegistry.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/SessionExecutionControllerTests.swift agentGuiTests/SessionExecutionRegistryTests.swift
git commit -m "feat: add session execution projection controllers"
```

### Task 3: 解耦 UI selection 与 execution ownership

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposerExecutionPresentation.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing test**

补 UI/状态测试覆盖：

- 选中会话变更不重置其它 session 的 projection。
- 会话列表能显示 background running / blocked 状态。
- toolbar / composer 用 projection 决定交互态，而不是读单一全局 streaming flag。

```swift
@Test func sessionListPrefersProjectionStateOverSelectionState() {
    let projection = SessionExecutionProjection.preview(
        sessionID: "s1",
        activityState: .running,
        presentationState: .background,
        needsAttention: false
    )

    #expect(ChatComposerExecutionPresentation.from(projection).showsRunningBadge)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with selection-coupled behavior or missing background execution presentation.

**Step 3: Write minimal implementation**

将 selection 和 execution 状态分离：

```swift
final class WorkspaceState {
    var selectedSession: Session?
    var executionRegistry: SessionExecutionRegistry?
}
```

`ChatView` / `SessionListView` 统一从 projection 读取运行态。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkspaceState.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView.swift agentGui/Views/ChatView+Toolbar.swift agentGui/Views/ChatComposerExecutionPresentation.swift agentGuiTests/WorkspaceStateTests.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift
git commit -m "feat: decouple selected session from execution state"
```

### Task 4: 把 built-in execution state 和交互中心改成 session-scoped

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionInteractionCenter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+AskUserQuestion.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+BashTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BuiltInSessionExecutionRegistryTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionInteractionCenterTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceMessagingTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

**Step 1: Write the failing test**

锁定以下行为：

- 两个 built-in session 可以同时持有独立 `currentInputTokens` 和 `currentModelID`
- `requestApprovalIfNeeded` 不再依赖 `claudeService.currentSession`
- `ask_user_question` 和 bash prompt 均以 `sessionID` 为键发布

```swift
@Test func toolApprovalUsesSessionScopedContextInsteadOfCurrentSession() async throws {
    let registry = BuiltInSessionExecutionRegistry()
    await registry.context(for: "s1").markRunning()

    let approved = await BuiltInApprovalHarness.resolve(sessionID: "s1", registry: registry)
    #expect(approved)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/BuiltInSessionExecutionRegistryTests -only-testing:agentGuiTests/SessionInteractionCenterTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with global `currentSession`, global `pendingUserQuestion`, or approval routing tied to foreground session.

**Step 3: Write minimal implementation**

```swift
struct BuiltInSessionExecutionContext: Sendable {
    let sessionID: String
    var isRunning: Bool
    var currentInputTokens: Int
    var currentModelID: String
    var pendingUserQuestion: AskUserQuestionRequest?
}
```

并新增：

```swift
@MainActor
final class SessionInteractionCenter {
    func publishUserQuestion(_ request: AskUserQuestionRequest, for sessionID: String) { ... }
    func publishToolApproval(_ request: ToolApprovalRequest, for sessionID: String) { ... }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/BuiltInSessionExecutionRegistryTests -only-testing:agentGuiTests/SessionInteractionCenterTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift agentGui/Services/Execution/SessionInteractionCenter.swift agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/Services/ClaudeService/ClaudeService+AskUserQuestion.swift agentGui/Services/ClaudeService/ClaudeService+BashTool.swift agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGuiTests/BuiltInSessionExecutionRegistryTests.swift agentGuiTests/SessionInteractionCenterTests.swift agentGuiTests/ClaudeServiceMessagingTests.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift
git commit -m "refactor: make built-in execution state session scoped"
```

### Task 5: 将 ACP activation 改为非破坏性 warmup

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderRuntimeSupervisorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPSessionRuntimeActorTests.swift`

**Step 1: Write the failing test**

新增测试覆盖：

- `warmSessionRuntimeIfNeeded(session:B)` 只 warm B，不触碰 A
- provider 不再在 `prepareForActivation` 期间调用 `deactivateAllSessionRuntimes()`
- capacity 未满时，A、B 两个 session runtime actor 可以并存

```swift
@Test func warmupDoesNotCloseSiblingSessionRuntime() async throws {
    let harness = try ACPWarmupHarness.make()
    try await harness.prepare(sessionID: "A")
    try await harness.prepare(sessionID: "B")

    #expect(await harness.closeCount(sessionID: "A") == 0)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPProviderRuntimeSupervisorTests -only-testing:agentGuiTests/ACPSessionRuntimeActorTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with current destructive activation semantics.

**Step 3: Write minimal implementation**

把 lifecycle API 改成 warmup 语义：

```swift
func warmSessionRuntimeIfNeeded(
    session: Session,
    modelContext: ModelContext,
    reason: RuntimeWarmupReason
) async
```

同时删掉 selection 驱动的 sibling teardown 路径。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPProviderRuntimeSupervisorTests -only-testing:agentGuiTests/ACPSessionRuntimeActorTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ConversationExecutionRuntimeCoordinator.swift agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ACP/ACPProviderRuntimeSupervisor.swift agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPProviderRuntimeSupervisorTests.swift agentGuiTests/ACPSessionRuntimeActorTests.swift
git commit -m "refactor: replace destructive acp activation with warmup"
```

### Task 6: 固化 ACP runtime client / transport / local handler 的 session 隔离

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPManagedClientRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPConnection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPLocalClientHandler.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPManagedClientRuntimeTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPConnectionTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPLocalClientHandlerTests.swift`

**Step 1: Write the failing test**

锁定隔离边界：

- 一个 client 只能附着一个 remote session；第二个 session 必须走第二个 runtime client
- `transport.close()` 只 fail 当前 connection 的 pending requests
- `ACPLocalClientHandler.terminalStates` 不跨 session 泄漏
- rebuild activation 后旧更新被丢弃

```swift
@Test func closingOneManagedRuntimeDoesNotFailSiblingSessionConnection() async throws {
    let pair = try ACPParallelRuntimeHarness.make()
    try await pair.runtimeA.initialize()
    try await pair.runtimeB.initialize()

    await pair.runtimeA.close()

    #expect(try await pair.runtimeB.prompt("still-alive") == .endTurn)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ACPManagedClientRuntimeTests -only-testing:agentGuiTests/ACPConnectionTests -only-testing:agentGuiTests/ACPLocalClientHandlerTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with shared-state leakage or missing activation discard behavior.

**Step 3: Write minimal implementation**

保持单 client 单 remote session，不做跨 session 复用：

```swift
if let attachedSessionHandshake, attachedSessionHandshake.remoteSessionID != requestedID {
    throw ACPExternalAgentRuntimeError.sessionAlreadyAttached(...)
}
```

并在 actor / handler 边界上清理所有 session-local state。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ACPManagedClientRuntimeTests -only-testing:agentGuiTests/ACPConnectionTests -only-testing:agentGuiTests/ACPLocalClientHandlerTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPSessionRuntimeActor.swift agentGui/Services/ACP/ACPManagedClientRuntime.swift agentGui/Services/ACP/ACPConnection.swift agentGui/Services/ACP/ACPLocalClientHandler.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/ACPManagedClientRuntimeTests.swift agentGuiTests/ACPConnectionTests.swift agentGuiTests/ACPLocalClientHandlerTests.swift
git commit -m "fix: enforce session scoped acp runtime isolation"
```

### Task 7: 用 capacity policy 替换 runtime scope 串行锁

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ProviderExecutionCapacityPolicy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionSchedulingModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`

**Step 1: Write the failing test**

新增测试锁定：

- 同 provider 下两个不同 session 可并发 admit
- 同一 session 仍只 admit 一个 job
- capacity 满了时新 job 排队，不抢占老 job

```swift
@Test func schedulerAdmitsTwoBuiltInSessionsWhenCapacityAllows() async {
    let scheduler = ExecutionScheduler(maxConcurrentJobs: 4)
    let candidates = [
        ExecutionSchedulingCandidate(... sessionID: "A", providerID: .builtInAgent),
        ExecutionSchedulingCandidate(... sessionID: "B", providerID: .builtInAgent)
    ]

    let admitted = await scheduler.admitReadyJobs(candidates)
    #expect(admitted.count == 2)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-7 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because current `runtimeScope` reservation still serializes sessions.

**Step 3: Write minimal implementation**

```swift
struct ProviderExecutionCapacityPolicy: Sendable {
    let providerID: ConversationExecutionProviderID
    let maxConcurrentSessions: Int
    let maxConcurrentJobsPerSession: Int
    let allowsBackgroundExecution: Bool
}
```

调度阶段按 provider policy + session occupancy 决定 admission，不再用 `reservedRuntimeScopes`.

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-7 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ProviderExecutionCapacityPolicy.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/Execution/ExecutionSchedulingModels.swift agentGui/Services/Execution/ExecutionScheduler.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGuiTests/ExecutionSchedulerTests.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift
git commit -m "feat: add provider capacity based execution scheduling"
```

### Task 8: 把慢路径从 MainActor 下沉并补恢复逻辑

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderContracts.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceMessagingTests.swift`

**Step 1: Write the failing test**

补测试覆盖：

- `initialize` / `loadSession` 超时只影响目标 session runtime
- `restorePendingJobs()` 恢复的是所有 running / pending session，不依赖当前 selected session
- built-in / ACP 后台运行时，前台状态对象只收到投影更新，不等待慢 IO 完成

```swift
@Test func restorePendingJobsRecoversBackgroundSessionsWithoutSelectionBootstrap() async throws {
    let harness = try ExecutionRecoveryHarness.make()
    try await harness.seedRecoverableJob(sessionID: "background-A")

    await harness.restorePendingJobs()

    #expect(await harness.wasRecovered("background-A"))
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-8 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL with lingering `@MainActor` slow-path assumptions or selection-coupled restore.

**Step 3: Write minimal implementation**

把慢路径封装到后台 actor / task，再回主线程发布状态：

```swift
let handshake = try await runtimeActor.prepareRuntimeSession(workingDirectory: workingDirectory)
await MainActor.run {
    projectionStore.markRunning(...)
}
```

同时让 orchestrator 启动时恢复所有 recoverable jobs。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-8 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderContracts.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift agentGuiTests/ClaudeServiceMessagingTests.swift
git commit -m "refactor: move runtime slow paths off main actor"
```

### Task 9: 做集成收口、文档对齐与最终验收

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-26-multi-session-parallel-execution-architecture.md`（如实现细节需要回填术语或阶段状态）
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-26-multi-session-parallel-execution-implementation-plan.md`（只在执行中记录必要纠偏，不新增任务）
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ClaudeServiceMessagingTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing test**

如果前面任务已覆盖完验收场景，这一步不加新测试；先把验收清单整理成可执行命令集。

```swift
// No new production code. Use existing suites as acceptance gates.
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-final -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS. If it fails, fix the regression before proceeding.

**Step 3: Write minimal implementation**

只做必要的 doc/wording 对齐，不新增行为。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-multisession-plan-final -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests -only-testing:agentGuiTests/ClaudeServiceMessagingTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO`

Expected: PASS.

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-26-multi-session-parallel-execution-architecture.md docs/plans/2026-03-26-multi-session-parallel-execution-implementation-plan.md
git commit -m "docs: finalize multi-session execution implementation plan"
```

## 5. 完成定义

- 会话切换不再决定 provider runtime teardown。
- built-in 与 ACP 都支持不同 session 并行推进。
- approval / `ask_user_question` / terminal prompt 都按 `sessionID` 隔离。
- ACP runtime client、connection、transport、local handler 均保持 session-scoped 隔离。
- `ExecutionScheduler` 不再把 `.builtIn` / `.externalACP` 当作全局锁。
- 慢路径不阻塞 `MainActor`，前台输入与切换体验保持流畅。
- 所有目标测试通过，并完成一次 @requesting-code-review。
