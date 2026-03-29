# Execution Projection Single Source Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce a single reducer-backed write path for `SessionExecutionProjection` so enqueue, restore, start, finish, and prune all flow through one execution lifecycle API, while `SessionExecutionController` stops writing back into `ExecutionProjectionStore`.

**Architecture:** Keep `ExecutionProjectionStore` as the published projection holder, but move all execution-state mutation into a pure reducer plus a small event DTO/protocol boundary. `ConversationExecutionOrchestrator` should emit projection lifecycle events instead of hand-assembling `SessionExecutionProjection`, and `SessionExecutionController` should become a read-only compatibility adapter until Feature 2 removes the registry layer entirely.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing execution subsystem (`ConversationExecutionOrchestrator`, `ExecutionProjectionStore`, `ExecutionPersistenceStore`, `SessionExecutionRegistry`).

---

## 1. Implementation Rules

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 1，不提前做 Feature 2 的 registry 全量删除、Feature 3 的 runtime truth 下沉，避免范围失控。
- 严格按 @test-driven-development 执行：每个任务先补失败测试，再写最小实现，再跑通过，再提交。
- 不要引入完整 event sourcing 平台；Feature 1 只需要一个轻量 reducer 和统一事件入口。
- `recovering` 覆盖指的是“恢复链路经过同一 reducer 路径”，不是给 `SessionExecutionActivityState` 新增 `.recovering` 枚举；当前投影模型仍然只发布 `.queued` 或 `.running`。
- Feature 1 的验收计数包含测试代码。仅消除生产代码中的手工 `SessionExecutionProjection(...)` 还不够，测试夹具也必须收敛。
- 删除优先于叠加兼容层，但 `SessionExecutionRegistry` 本体保留到 Feature 2；本轮只移除它的写入职责。
- 最终回归后，用 @requesting-code-review 做一次 focused review，重点检查：单写口是否成立、Orchestrator 是否完全脱离手工拼 projection、Controller 是否彻底停止回写 store。

## 2. Current State Summary

- `ConversationExecutionOrchestrator` 当前在 `enqueue`, `restorePendingJobs`, `updateProjectionForRunningJob`, `finish`, `updateProjectionAfterPruningQueuedJob` 五个路径中直接构造 `SessionExecutionProjection`。
- `SessionExecutionController` 通过 `projection.didSet` 反向写 `ExecutionProjectionStore`，形成第二条写链路。
- `SessionExecutionRegistry.projection(for:)` 依赖 `syncFromStore()` 修补 controller 副本过期问题，这说明当前模型仍然是“双写 + 显式补同步”。
- `WorkspaceStateTests`, `ChatComposerExecutionPresentationTests`, `ConversationExecutionRuntimeCoordinatorTests`, `ConversationExecutionRecoveryTests` 里还存在多处裸 `SessionExecutionProjection(...)` 初始化，如果不统一成 fixture/helper，验收标准 1 无法通过。

## 3. Desired End State

完成后应满足以下条件：

1. `ExecutionProjectionStore` 提供统一的 `apply(event:)` 或等价 API，内部通过 reducer 产生新 projection。
2. `ConversationExecutionOrchestrator` 只发 projection lifecycle event，不直接构造 `SessionExecutionProjection`。
3. `SessionExecutionController` 不再有 `didSet -> projectionStore.setProjection(...)` 回写；它只能读 store，或完全变成 store 的轻量 facade。
4. `restorePendingJobs()` 与实时 enqueue/start/finish/prune 路径共享同一 reducer 规则。
5. 仓库内裸 `SessionExecutionProjection(...)` 组装点收敛到 5 处以内，剩余调用只能是 sanctioned helper、`empty(sessionID:)` 或确有必要的测试边界断言。

## 4. Target Files

### New production files

- `agentGui/Services/Execution/SessionExecutionProjectionEvent.swift`
- `agentGui/Services/Execution/SessionExecutionProjectionReducer.swift`

### New test support / tests

- `agentGuiTests/SessionExecutionProjectionReducerTests.swift`
- `agentGuiTests/TestSupport/SessionExecutionProjectionFixtures.swift`

### Primary production files to modify

- `agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `agentGui/Services/Execution/SessionExecutionController.swift`
- `agentGui/Services/Execution/SessionExecutionRegistry.swift`
- `agentGui/Models/ExecutionProjection.swift`
- `agentGui/Utilities/WorkspaceState.swift`

### Primary tests to modify

- `agentGuiTests/ExecutionProjectionStoreTests.swift`
- `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- `agentGuiTests/SessionExecutionControllerTests.swift`
- `agentGuiTests/SessionExecutionRegistryTests.swift`
- `agentGuiTests/WorkspaceStateTests.swift`
- `agentGuiTests/ChatComposerExecutionPresentationTests.swift`
- `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`

## 5. Task Breakdown

### Task 1: 锁定 reducer 目标行为

**Files:**
- Create: `agentGuiTests/SessionExecutionProjectionReducerTests.swift`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing tests**

新增一个纯 reducer 测试文件，至少覆盖 6 条路径：

- `enqueue` 把 job 追加到 `queuedJobIDs` 并进入 `.queued`
- `start` 把 job 从队列头移到 `runningJobID` 并进入 `.running`
- `finish(cancelled)` 清空 `runningJobID`，保留剩余排队 job，并清空 `currentPhase`
- `finish(failed)` 与取消路径共享同一收敛规则，但保留后续可继续提交状态
- `recover` 通过恢复事件重建 `.queued` 或 `.running` 投影
- `prune` 删除失效队列 job 且不污染其他 session 字段

建议测试代码骨架：

```swift
import Testing
@testable import agentGui

struct SessionExecutionProjectionReducerTests {
    @Test
    func enqueueEventAppendsQueuedJobAndMarksQueued() {
        let jobID = UUID()
        let event = SessionExecutionProjectionEvent.enqueued(
            sessionID: "session-a",
            jobID: jobID,
            providerReference: .builtIn
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: event
        )

        #expect(reduced.queuedJobIDs == [jobID])
        #expect(reduced.queuedCount == 1)
        #expect(reduced.activityState == .queued)
        #expect(reduced.activeProviderReference == .builtIn)
    }

    @Test
    func failedFinishClearsRunningAndFallsBackToIdleWhenQueueIsEmpty() {
        let jobID = UUID()
        let current = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            runningJobID: jobID,
            queuedJobIDs: [],
            isRunning: true,
            activeProviderReference: .builtIn,
            currentPhase: .executing,
            activityState: .running
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: .finished(
                sessionID: "session-a",
                jobID: jobID,
                outcome: .failed
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.isRunning == false)
        #expect(reduced.currentPhase == nil)
        #expect(reduced.activityState == .idle)
    }
}
```

在 `ConversationExecutionRecoveryTests` 新增一条恢复链路断言，目标是锁定“恢复走 reducer 事件，而不是手工 setProjection”：

```swift
@Test
func restorePendingJobsRehydratesProjectionThroughRecoveryEvent() async throws {
    let harness = try ExecutionRecoveryHarness.make()
    try await harness.seedRecoverableRunningJob(sessionID: "recover-a")

    await harness.orchestrator.restorePendingJobs()

    let projection = harness.projectionStore.projection(for: "recover-a")
    #expect(projection.activityState == .running || projection.activityState == .queued)
    #expect(projection.activeProviderReference == .builtIn)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature1-task1 -only-testing:agentGuiTests/SessionExecutionProjectionReducerTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because reducer/event types and store apply API do not exist yet.

**Step 3: Write minimal implementation**

先只补最小可测骨架，不迁移 Orchestrator：

- 新建 `SessionExecutionProjectionEvent`
- 新建 `SessionExecutionProjectionReducer.reduce(current:event:)`
- 在 `ExecutionProjectionStore` 里加 `apply(_:)`

建议初始接口：

```swift
enum SessionExecutionProjectionEvent: Sendable, Equatable {
    case enqueued(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case recovered(sessionID: String, queuedJobIDs: [UUID], runningJobID: UUID?, providerReference: ExecutionProviderReference?)
    case started(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case finished(sessionID: String, jobID: UUID, outcome: ExecutionJobState)
    case pruned(sessionID: String, jobID: UUID)
    case presentationChanged(sessionID: String, state: SessionExecutionPresentationState)
}
```

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command again.

Expected: PASS for reducer/store unit coverage; recovery integration test may still remain pending until Task 3, so mark it with `#expect` against current behavior only after Orchestrator migration if needed.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionExecutionProjectionEvent.swift agentGui/Services/Execution/SessionExecutionProjectionReducer.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGuiTests/SessionExecutionProjectionReducerTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "test: lock execution projection reducer behavior"
```

### Task 2: 让 store 成为唯一 lifecycle 写入口

**Files:**
- Modify: `agentGui/Services/Execution/ExecutionProjectionStore.swift`
- Modify: `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing tests**

为 Orchestrator 增加“只通过 store.apply(event:) 写投影”的回归测试。最简单的做法是给 Orchestrator 注入一个小协议，而不是直接依赖具体 store：

```swift
@MainActor
protocol SessionExecutionProjectionWriting: AnyObject {
    func projection(for sessionID: String) -> SessionExecutionProjection
    func apply(_ event: SessionExecutionProjectionEvent)
}
```

然后用 recording spy 断言事件顺序：

```swift
@Test
func enqueueStartFinishPruneEmitReducerEventsInOrder() async throws {
    let writer = RecordingProjectionWriter()
    let harness = try ExecutionRecoveryHarness.make(projectionWriter: writer)
    let session = try harness.makeSession(id: "ordered-session")
    let handle = try await harness.enqueuePrompt(text: "hello", in: session)

    #expect(writer.events.contains(.enqueued(
        sessionID: session.sessionId,
        jobID: handle.jobID,
        providerReference: .builtIn
    )))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature1-task2 -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `ConversationExecutionOrchestrator` still constructs projections directly.

**Step 3: Write minimal implementation**

做以下最小改动：

- `ConversationExecutionOrchestrator` 依赖 `SessionExecutionProjectionWriting`
- 用 `projectionWriter.apply(.enqueued(...))` 取代 `enqueue` 里的手工构造
- 用 `projectionWriter.apply(.recovered(...))` 取代 `restorePendingJobs()` 的手工构造
- 用 `projectionWriter.apply(.started(...))` 取代 `updateProjectionForRunningJob`
- 用 `projectionWriter.apply(.finished(...))` 取代 `finish`
- 用 `projectionWriter.apply(.pruned(...))` 取代 `updateProjectionAfterPruningQueuedJob`

注意：不要在 reducer 外部再拼 `queuedCount`, `activityState`, `currentPhase`，这些都必须内聚在 reducer 内。

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command again.

Expected: PASS, and `ConversationExecutionRecoveryTests` 能证明恢复路径与实时路径共用同一套 projection 转移规则。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "refactor: route execution projection writes through reducer"
```

### Task 3: 移除 SessionExecutionController 的反向写回

**Files:**
- Modify: `agentGui/Services/Execution/SessionExecutionController.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionRegistry.swift`
- Modify: `agentGui/Utilities/WorkspaceState.swift`
- Modify: `agentGuiTests/SessionExecutionControllerTests.swift`
- Modify: `agentGuiTests/SessionExecutionRegistryTests.swift`
- Modify: `agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing tests**

把现有 controller/registry 测试改成“只能读 store，不再写 store”：

- `SessionExecutionControllerTests` 不再调用 `recordRunning` / `recordBlocked`
- 新增 `controllerReflectsStoreProjectionWithoutWriteBack()`
- 新增 `registryForegroundSelectionUsesPresentationEvent()`
- `WorkspaceStateTests` 改为通过 store 变化观察 UI projection，而不是通过 controller 写入

建议测试骨架：

```swift
@Test
func controllerReflectsStoreProjectionWithoutWriteBack() {
    let store = ExecutionProjectionStore()
    let controller = SessionExecutionController(sessionID: "session-a", projectionStore: store)

    store.apply(.enqueued(
        sessionID: "session-a",
        jobID: UUID(),
        providerReference: .builtIn
    ))

    #expect(controller.projection.activityState == .queued)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature1-task3 -only-testing:agentGuiTests/SessionExecutionControllerTests -only-testing:agentGuiTests/SessionExecutionRegistryTests -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because controller still owns mutating APIs and `didSet` write-back.

**Step 3: Write minimal implementation**

把 controller 降级为兼容读 facade：

- 删除 `projectionStore?.setProjection(self.projection)` 初始化写入
- 删除 `projection.didSet { projectionStore?.setProjection(projection) }`
- 删除或 `@available(*, deprecated)` 标记 `recordQueued`, `recordRunning`, `recordBlocked`, `recordIdle`, `setPresentationState`
- `projection` 改为从 store 拉取，或者只允许 `syncFromStore()` 更新本地缓存，不允许任何反向写回
- `SessionExecutionRegistry.setForegroundSession(_:)` 改为对 store 发 `presentationChanged` 事件，而不是迭代 controller 修改本地 projection

如果 `WorkspaceState.selectedSession` 仍然需要兼容 registry API，就让它继续调用 `executionRegistry.setForegroundSession(...)`，但内部只能下发 store event。

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command again.

Expected: PASS, 且不再出现“controller 变更带动 store 反写”的路径。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionExecutionController.swift agentGui/Services/Execution/SessionExecutionRegistry.swift agentGui/Utilities/WorkspaceState.swift agentGuiTests/SessionExecutionControllerTests.swift agentGuiTests/SessionExecutionRegistryTests.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "refactor: make execution controller read-only"
```

### Task 4: 收敛测试夹具和 UI 投影样例

**Files:**
- Create: `agentGuiTests/TestSupport/SessionExecutionProjectionFixtures.swift`
- Modify: `agentGuiTests/ChatComposerExecutionPresentationTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `agentGuiTests/SessionExecutionRegistryTests.swift`
- Modify: `agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing tests**

先新增统一 fixture helper，再把多处裸 initializer 替换为 helper 调用。建议 helper 形态：

```swift
@testable import agentGui

extension SessionExecutionProjection {
    static func fixture(
        sessionID: String = "session-a",
        runningJobID: UUID? = nil,
        queuedJobIDs: [UUID] = [],
        isRunning: Bool = false,
        activeProviderReference: ExecutionProviderReference? = nil,
        currentPhase: AgentLoopPhase? = nil,
        activityState: SessionExecutionActivityState = .idle,
        presentationState: SessionExecutionPresentationState = .foreground,
        needsAttention: Bool = false,
        attentionReason: SessionExecutionAttentionReason? = nil
    ) -> SessionExecutionProjection {
        SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: runningJobID,
            queuedJobIDs: queuedJobIDs,
            queuedCount: queuedJobIDs.count,
            isRunning: isRunning,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderReference: activeProviderReference,
            currentPhase: currentPhase,
            activityState: activityState,
            presentationState: presentationState,
            needsAttention: needsAttention,
            attentionReason: attentionReason
        )
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature1-task4 -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/SessionExecutionRegistryTests -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until all tests compile against the new fixture helper and any controller write-path assumptions are removed.

**Step 3: Write minimal implementation**

- 新增 `SessionExecutionProjection.fixture(...)`
- 用它替换测试中的绝大多数裸 `SessionExecutionProjection(...)`
- 仅保留极少数必须直接断言 initializer 参数语义的测试点

目标不是“一个都不留”，而是把仓库总量压到验收要求的 5 处以内。

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/TestSupport/SessionExecutionProjectionFixtures.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/SessionExecutionRegistryTests.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "test: consolidate execution projection fixtures"
```

### Task 5: 验收单写口并清理残留手工组装

**Files:**
- Modify: `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionController.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionRegistry.swift`
- Modify: `agentGuiTests/SessionExecutionProjectionReducerTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing verification checks**

补最后两类回归：

- reducer 要覆盖 queued、running、cancelled、failed、recovering 五种路径
- `rg` 计数必须证明仓库内手工 `SessionExecutionProjection(...)` 组装小于等于 5 处

推荐新增一条 reducer 测试，把 cancelled 与 failed 显式分开：

```swift
@Test
func cancelledFinishKeepsQueuedTailReadyForNextDispatch() {
    let running = UUID()
    let queued = UUID()
    let current = SessionExecutionProjection.fixture(
        runningJobID: running,
        queuedJobIDs: [queued],
        isRunning: true,
        activeProviderReference: .builtIn,
        currentPhase: .executing,
        activityState: .running
    )

    let reduced = SessionExecutionProjectionReducer.reduce(
        current: current,
        event: .finished(sessionID: "session-a", jobID: running, outcome: .cancelled)
    )

    #expect(reduced.runningJobID == nil)
    #expect(reduced.queuedJobIDs == [queued])
    #expect(reduced.activityState == .queued)
}
```

**Step 2: Run verification commands and confirm failure/pass**

Run the focused suite:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature1-final -only-testing:agentGuiTests/SessionExecutionProjectionReducerTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/SessionExecutionControllerTests -only-testing:agentGuiTests/SessionExecutionRegistryTests -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Run the initializer count check:

```bash
rg -n 'SessionExecutionProjection\(' agentGui agentGuiTests
```

Expected after cleanup:

- tests PASS
- `rg` output <= 5 matches
- remaining matches are intentional helpers or boundary assertions only

**Step 3: Final cleanup**

如果 `rg` 结果仍然超过 5 处，继续把残余裸 initializer 收敛到 helper 或 reducer 中，优先清理：

- `ConversationExecutionRuntimeCoordinatorTests`
- `ChatComposerExecutionPresentationTests`
- `WorkspaceStateTests`
- 任何仍在生产代码中的 direct `SessionExecutionProjection(...)`

**Step 4: Commit**

```bash
git add agentGui agentGuiTests
git commit -m "refactor: unify execution projection write path"
```

## 6. Risks And Review Checklist

- 风险 1：如果把 `presentationChanged` 留在 controller 私有路径，Feature 1 看似完成，但实际上 store 仍有第二写入口。Review 时必须确认 foreground/background 也走 store event。
- 风险 2：如果 `recovering` 路径只做恢复后断言、不校验事件入口，就会再次回到“恢复特殊分支手工拼 projection”。
- 风险 3：如果测试夹具不统一，仓库级 `SessionExecutionProjection(...)` 数量依旧超标，Feature 1 验收无法关闭。
- 风险 4：如果 Orchestrator 仍然需要先读当前 projection 再在外部计算 `queuedCount` 或 `activityState`，说明 reducer 还没有真正接管状态转移。

Review checklist:

1. `ConversationExecutionOrchestrator` 中是否已删除所有 lifecycle 相关 `SessionExecutionProjection(...)` 组装。
2. `SessionExecutionController` 是否已经没有任何写回 `ExecutionProjectionStore` 的路径。
3. `restorePendingJobs`, `enqueue`, `start`, `finish`, `prune` 是否统一走 `apply(event:)`。
4. `SessionExecutionProjectionReducerTests` 是否显式覆盖 queued、running、cancelled、failed、recovering。
5. `rg -n 'SessionExecutionProjection\(' agentGui agentGuiTests` 是否小于等于 5。

## 7. Done Definition

Feature 1 可以关闭的标准：

1. `ConversationExecutionOrchestrator` 不再手工构造 `SessionExecutionProjection`。
2. `SessionExecutionController` 不再反向写 `ExecutionProjectionStore`。
3. `ExecutionProjectionStore` 或其等价 facade 成为唯一 projection 写入口。
4. 恢复和实时路径共享同一 reducer。
5. focused test suite 通过，且裸 `SessionExecutionProjection(...)` 组装点小于等于 5。

Plan complete and saved to `docs/plans/2026-03-29-execution-projection-single-source-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**