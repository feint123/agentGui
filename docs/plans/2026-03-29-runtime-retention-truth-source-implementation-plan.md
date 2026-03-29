# Runtime Retention Truth Source Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce an execution-runtime truth source for runtime retention so `ConversationExecutionRuntimeCoordinator` no longer decides retain/release behavior from `SessionExecutionProjection` snapshots.

**Architecture:** Keep `ExecutionProjectionStore` as the UI-facing projection source introduced by Feature 1, but add a separate reducer-backed runtime state store that derives from the same execution lifecycle events. `ConversationExecutionRuntimeCoordinator` should consume runtime snapshots plus its own foreground/dispatch lease state, while `ConversationExecutionOrchestrator` remains the only lifecycle event producer.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing execution subsystem (`ConversationExecutionOrchestrator`, `ConversationExecutionRuntimeCoordinator`, `ExecutionProjectionStore`, `ConversationExecutionProviderRegistry`).

---

## 1. Implementation Rules

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 3，不提前落地 Feature 4 的完整 session runtime event bus、diagnostics 面板或 recovery 异步化。
- Feature 3 依赖 Feature 1 已完成：`ConversationExecutionOrchestrator` 必须继续只从统一 lifecycle event 路径发出状态变更，不允许重新引入手工拼装 `SessionExecutionProjection` 的旁路。
- 严格按 @test-driven-development 执行：每个任务必须先写失败测试，再验证红灯，再写最小实现，再跑回归。
- `ExecutionProjectionStore` 继续服务 UI；它不再作为 runtime retention 的决策输入。
- runtime retention 的真值范围只包括“是否仍有运行中的 execution，以及该 execution 归属哪个 provider reference / runtime scope”。queued UI、presentation UI、attention UI 仍由 projection 决定。
- 不要在 Feature 3 中把所有 retention 逻辑搬成通用事件总线；只做让 coordinator 摆脱 projection 依赖所必需的最小 store、DTO、fanout 和测试夹具调整。
- 现有 focused tests 必须保留；新增测试必须显式覆盖“projection 滞后但 runtime snapshot 正确”的场景。
- 回归完成后，用 @requesting-code-review 做一次 focused review，重点检查：runtime coordinator 是否完全脱离 projection 读取、orchestrator 是否仍保持单一 lifecycle 写口、projection lag 场景是否被测试钉住。

## 2. Current State Summary

- `ConversationExecutionRuntimeCoordinator` 当前通过 `ExecutionProjectionStore.projection(for:)` 读取 `isRunning` 和 `activeProviderReference`，见 `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`。
- `shouldProtectRuntime(for:in:registry:)` 和 `shouldProtectRuntime(for:providerReference:in:registry:)` 都直接依赖 projection，所以 retention 的真值前提是“projection 已经及时发布”。
- `ConversationExecutionOrchestrator` 已经在 enqueue / recover / start / finish / prune 路径统一调用 `projectionWriter.apply(...)`，这为 Feature 3 提供了稳定的 lifecycle 事件源。
- `ConversationExecutionRuntimeCoordinatorTests` 里大量通过 `projectionStore.setProjection(.fixture(...))` 人工制造运行中状态，这正是当前耦合点；Feature 3 完成后这些测试必须迁移到 runtime state fixture。
- `ConversationExecutionRecoveryTests` 的 harness 目前常用 `ConversationExecutionRuntimeCoordinator()` 默认初始化，而不是共享某个额外的 runtime truth store；Feature 3 需要把注入关系显式化，避免测试仍然隐式依赖 projection。

## 3. Desired End State

完成后应满足以下条件：

1. `ConversationExecutionOrchestrator` 发出的 execution lifecycle event 可以同时驱动 UI projection reducer 和 runtime state reducer，但 orchestrator 自身仍只知道一个 fanout 写口。
2. `ConversationExecutionRuntimeCoordinator` 只读取独立的 session runtime snapshot，不再直接访问 `ExecutionProjectionStore`。
3. foreground lease、dispatch lease、running lease 的优先级被编码为显式规则，而不是隐含在 projection 字段组合里。
4. projection 允许滞后发布，但只要 runtime snapshot 仍显示 `runningJobID != nil` 且 provider reference 仍在对应 scope，runtime 就不会被错误释放。
5. 当 runtime snapshot 显示 execution 已结束时，即使 UI projection 还暂时显示 running，`reconcileRuntimeRetention(...)` 也会按 runtime truth 释放后台 runtime。
6. `ClaudeService`、focused tests、测试 harness 都会注入同一个 runtime state store，杜绝“只有共享 projection store 才能通过”的隐式前提。

## 4. Retention Priority Rules

Feature 3 的核心不是新增更多状态，而是把优先级规则写实。实现和测试都要围绕下面这张规则表展开。

1. `foreground lease` 最高优先级。当前 scope 的前台 session 一定被保活，与该 session 当前是否 running 无关。
2. `dispatch lease` 次高优先级。`executionDispatch` 触发后，在 runtime snapshot 尚未变成 running 之前，对应 session 和 provider reference 必须继续保活。
3. `running lease` 来自 runtime snapshot。只要 snapshot 显示某 session 的 `runningJobID` 仍存在，并且 `runningProviderReference` 落在当前 scope，该 session 必须继续保活。
4. `provider sibling release` 必须避开 dispatch lease owner 和 running lease owner。也就是说，同 session 切换 provider 时，只有“不再被 dispatch lease 或 running lease 保护”的 sibling provider 才能收到 `.providerBecameInactive`。
5. `release plan` 只处理从上一轮 retained set 到下一轮 retained set 的差集，不得根据 UI projection 直接推断 release。

## 5. File Map

### New production files

- `agentGui/Services/Execution/SessionExecutionRuntimeState.swift`
- `agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift`
- `agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift`
- `agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift`

### Production files to modify

- `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `agentGui/Services/ClaudeService/ClaudeService.swift`
- `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`

### Tests to create or modify

- `agentGuiTests/SessionExecutionRuntimeStateReducerTests.swift`
- `agentGuiTests/SessionExecutionRuntimeStateStoreTests.swift`
- `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

## 6. Task Breakdown

### Task 1: 锁定 runtime truth DTO 和 reducer 语义

**Files:**
- Create: `agentGui/Services/Execution/SessionExecutionRuntimeState.swift`
- Create: `agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift`
- Create: `agentGuiTests/SessionExecutionRuntimeStateReducerTests.swift`

**Step 1: Write the failing tests**

先写 reducer 级测试，锁定 Feature 3 需要的最小真值。建议 DTO 只保留 retention 必需字段：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionRuntimeStateReducerTests {
    @Test
    func startEventMarksRuntimeRunningForProviderReference() {
        let jobID = UUID()
        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .started(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == jobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.isRunning)
    }

    @Test
    func finishedEventClearsRunningLeaseButKeepsLastQueuedJobsOutOfRetention() {
        let jobID = UUID()
        let current = SessionExecutionRuntimeState.fixture(
            sessionID: "session-a",
            runningJobID: jobID,
            runningProviderReference: .builtIn,
            queuedJobIDs: [UUID()]
        )

        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: current,
            event: .finished(sessionID: "session-a", jobID: jobID, outcome: .completed)
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.runningProviderReference == nil)
        #expect(reduced.isRunning == false)
        #expect(reduced.queuedJobIDs.count == 1)
    }
}
```

再补两个边界测试：

- `recovered` 带 `runningJobID` 时能恢复 running lease。
- `pruned` 只影响 queued bookkeeping，不影响 running lease。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task1 -only-testing:agentGuiTests/SessionExecutionRuntimeStateReducerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示缺少 `SessionExecutionRuntimeState` 或 reducer 类型。

**Step 3: Write minimal implementation**

最小实现保持纯值对象，不依赖 SwiftData 或 UI store：

```swift
import Foundation

struct SessionExecutionRuntimeState: Equatable, Sendable {
    let sessionID: String
    let queuedJobIDs: [UUID]
    let runningJobID: UUID?
    let runningProviderReference: ExecutionProviderReference?

    var isRunning: Bool {
        runningJobID != nil && runningProviderReference != nil
    }

    static func empty(sessionID: String) -> SessionExecutionRuntimeState {
        SessionExecutionRuntimeState(
            sessionID: sessionID,
            queuedJobIDs: [],
            runningJobID: nil,
            runningProviderReference: nil
        )
    }
}
```

Reducer 只消费现有的 `SessionExecutionProjectionEvent`，不要在 Feature 3 新造第二套 lifecycle event 枚举。这样可以保持 Feature 1 的单一事件入口，并把 Feature 4 留给后续的总线抽象。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionExecutionRuntimeState.swift agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift agentGuiTests/SessionExecutionRuntimeStateReducerTests.swift
git commit -m "test: lock runtime retention truth reducer behavior"
```

### Task 2: 引入 runtime state store，并让 orchestrator 保持单一 lifecycle 写口

**Files:**
- Create: `agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift`
- Create: `agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift`
- Modify: `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Create: `agentGuiTests/SessionExecutionRuntimeStateStoreTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing tests**

先锁定 store 和 fanout 的行为，目标是“同一个 lifecycle event 同时更新 projection store 和 runtime state store，但 orchestrator 仍只调用一次 apply”。

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionRuntimeStateStoreTests {
    @Test
    func applyStartEventPublishesRunningRuntimeSnapshot() {
        let store = SessionExecutionRuntimeStateStore()
        let jobID = UUID()

        store.apply(.started(
            sessionID: "session-a",
            jobID: jobID,
            providerReference: .builtIn
        ))

        let snapshot = store.state(for: "session-a")
        #expect(snapshot.runningJobID == jobID)
        #expect(snapshot.runningProviderReference == .builtIn)
    }

    @Test
    func fanoutWriterUpdatesProjectionAndRuntimeStoresTogether() {
        let projectionStore = ExecutionProjectionStore()
        let runtimeStore = SessionExecutionRuntimeStateStore()
        let writer = SessionExecutionLifecycleFanoutWriter(
            projectionWriter: projectionStore,
            runtimeStateWriter: runtimeStore
        )

        writer.apply(.started(
            sessionID: "session-a",
            jobID: UUID(),
            providerReference: .builtIn
        ))

        #expect(projectionStore.projection(for: "session-a").isRunning)
        #expect(runtimeStore.state(for: "session-a").isRunning)
    }
}
```

然后在 `ConversationExecutionRecoveryTests` 加一条回归：`restorePendingJobs()` 恢复 running job 后，runtime state store 也应该变成 running，而不是只有 projection store 变化。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task2 -only-testing:agentGuiTests/SessionExecutionRuntimeStateStoreTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，提示 store、fanout writer 或 recovery harness 注入缺失。

**Step 3: Write minimal implementation**

建议把 runtime state store 设计成与 `ExecutionProjectionStore` 对齐的轻量 observable store：

```swift
import Foundation
import Observation

@Observable
@MainActor
final class SessionExecutionRuntimeStateStore {
    private(set) var states: [String: SessionExecutionRuntimeState] = [:]

    func state(for sessionID: String) -> SessionExecutionRuntimeState {
        states[sessionID] ?? .empty(sessionID: sessionID)
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        let sessionID = event.sessionID
        states[sessionID] = SessionExecutionRuntimeStateReducer.reduce(
            current: state(for: sessionID),
            event: event
        )
    }
}
```

fanout writer 只做组合，不做新业务决策：

```swift
@MainActor
final class SessionExecutionLifecycleFanoutWriter: SessionExecutionProjectionWriting {
    private let projectionWriter: any SessionExecutionProjectionWriting
    private let runtimeStateWriter: SessionExecutionRuntimeStateStore

    init(
        projectionWriter: any SessionExecutionProjectionWriting,
        runtimeStateWriter: SessionExecutionRuntimeStateStore
    ) {
        self.projectionWriter = projectionWriter
        self.runtimeStateWriter = runtimeStateWriter
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projectionWriter.projection(for: sessionID)
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        projectionWriter.apply(event)
        runtimeStateWriter.apply(event)
    }
}
```

`ClaudeService` 需要持有共享的 `SessionExecutionRuntimeStateStore`，并在创建 `ConversationExecutionRuntimeCoordinator` 与 `ConversationExecutionOrchestrator` 时显式注入。`ConversationExecutionRecoveryTests` 和其他 harness 也要同步改成共享 runtime state store。

**Step 4: Run test to verify it passes**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGuiTests/SessionExecutionRuntimeStateStoreTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "feat: fan out execution lifecycle events to runtime truth store"
```

### Task 3: 让 runtime coordinator 从 runtime snapshot 决策 retain/release

**Files:**
- Modify: `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Modify: `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

**Step 1: Write the failing tests**

先把现有 coordinator focused tests 迁移到 runtime state fixture，而不是继续手动写 projection。至少新增以下两个红灯场景：

```swift
@Test
func selectionSwitchKeepsRunningRuntimeRetainedWhenProjectionIsStillIdle() async throws {
    let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
    let runtimeStore = SessionExecutionRuntimeStateStore()
    let projectionStore = ExecutionProjectionStore()
    let coordinator = ConversationExecutionRuntimeCoordinator(
        projectionStore: projectionStore,
        runtimeStateStore: runtimeStore
    )
    let firstProvider = RuntimeCoordinatorTestProvider(id: .githubCopilotCLI, runtimeScope: .externalACP)
    let secondProvider = RuntimeCoordinatorTestProvider(id: .openCodeCLI, runtimeScope: .externalACP)
    let registry = makeRegistry(
        builtIn: RuntimeCoordinatorTestProvider(id: .builtInAgent, runtimeScope: .builtIn),
        providers: [firstProvider, secondProvider]
    )

    await coordinator.prepareForActivation(
        session: harness.firstSession,
        activeProvider: firstProvider,
        registry: registry,
        modelContext: harness.context,
        trigger: .sessionBootstrap
    )

    runtimeStore.apply(.started(
        sessionID: harness.firstSession.sessionId,
        jobID: UUID(),
        providerReference: .githubCopilotCLI.compatibilityReference
    ))

    await coordinator.prepareForActivation(
        session: harness.secondSession,
        activeProvider: secondProvider,
        registry: registry,
        modelContext: harness.context,
        trigger: .selection
    )

    #expect(firstProvider.releasedRuntimeEvents.isEmpty)
}

@Test
func reconcileReleasesRuntimeWhenProjectionStillLooksRunningButRuntimeTruthFinished() async throws {
    // 先让 projection 保持 running，再只把 runtime store 更新为 finished。
    // 期望 reconcile 依据 runtime truth 释放，而不是被过时 projection 阻塞。
}
```

保留并迁移现有场景：

- `executionDispatchDoesNotEvictForegroundSessionLease`
- `selectionSwitchKeepsExecutionDispatchLeaseBeforeProjectionTurnsRunning`
- `switchingProviderInSameSessionKeepsDispatchLeaseOwnerRuntime`
- `selectionSwitchKeepsRunningDynamicProviderRuntimeRetainedByReference`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task3 -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，原因应是 coordinator 仍读取 projection store，或初始化签名还没接 runtime state store。

**Step 3: Write minimal implementation**

把 coordinator 依赖改成“projection store 仅用于兼容 sibling provider release 所需的 UI 状态时一律禁止使用；所有 protect/release 判断统一走 runtime snapshot”。如果 projection store 在这个文件里再也没有用途，就直接删掉依赖。

建议改造方向如下：

```swift
@MainActor
final class ConversationExecutionRuntimeCoordinator {
    private let runtimeStateStore: SessionExecutionRuntimeStateStore
    private var scopeStates: [ConversationExecutionRuntimeScope: ScopeState] = [:]

    init(runtimeStateStore: SessionExecutionRuntimeStateStore) {
        self.runtimeStateStore = runtimeStateStore
    }

    private func runtimeState(for sessionID: String) -> SessionExecutionRuntimeState {
        runtimeStateStore.state(for: sessionID)
    }

    private func shouldProtectRuntime(
        for sessionID: String,
        in scope: ConversationExecutionRuntimeScope,
        registry: ConversationExecutionProviderRegistry
    ) -> Bool {
        let state = runtimeState(for: sessionID)
        guard state.isRunning,
              let providerReference = state.runningProviderReference,
              let provider = registry.providerIfAvailable(for: providerReference) else {
            return false
        }

        return provider.runtimeScope == scope
    }
}
```

还需要把 `protectedProviderReferences` 的计算从单纯 dispatch lease 扩展成“dispatch lease provider refs ∪ 当前 running provider ref”，否则同 session 切换 provider 时会错误释放仍在运行的旧 provider runtime。

**Step 4: Run test to verify it passes**

先跑 Step 2 的 focused tests；通过后再补一轮 recovery 相关回归：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task3b -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ConversationExecutionRuntimeCoordinator.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "feat: drive runtime retention from runtime truth snapshots"
```

### Task 4: 补齐 projection lag 回归，并收敛测试夹具注入

**Files:**
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- Modify: `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

**Step 1: Write the failing tests**

增加两个明确命名的滞后测试，避免后续 Feature 4/8 重构时回退到 projection：

1. `projectionLagsBehindRunningRuntimeButRetentionStillHolds`
2. `projectionLagsBehindFinishedRuntimeButReconcileStillReleases`

并把测试夹具显式升级为：

- `makeProviderActivationHarness(runtimeStateStore:)`
- `ExecutionRecoveryHarness.make(runtimeStateStore:)`

使每个测试都能看出“coordinator 与 orchestrator 是否真的共享同一个 runtime truth store”。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task4 -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，直到所有测试不再依赖 `projectionStore.setProjection(.fixture(...running...))` 作为 retention 真值。

**Step 3: Write minimal implementation**

这里的“实现”主要是测试夹具收敛，不是新增生产功能：

- 提供 runtime state fixture helper，例如：

```swift
extension SessionExecutionRuntimeState {
    static func fixture(
        sessionID: String = "session-a",
        queuedJobIDs: [UUID] = [],
        runningJobID: UUID? = nil,
        runningProviderReference: ExecutionProviderReference? = nil
    ) -> SessionExecutionRuntimeState {
        SessionExecutionRuntimeState(
            sessionID: sessionID,
            queuedJobIDs: queuedJobIDs,
            runningJobID: runningJobID,
            runningProviderReference: runningProviderReference
        )
    }
}
```

- 如有必要，为 runtime state store 增加仅测试使用的 `setState(_:)` API，或者保持只走 `apply(event:)`，二选一即可。默认推荐继续只走 `apply(event:)`，以免测试引入一条生产代码没有的旁路。

**Step 4: Run test to verify it passes**

先跑 focused tests：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task4b -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

再跑现有任务里的 runtime baseline：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-task4c -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift
git commit -m "test: cover projection lag runtime retention scenarios"
```

## 7. Validation Checklist

完成全部任务后，按下面顺序验证：

1. `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-truth-final -only-testing:agentGuiTests/SessionExecutionRuntimeStateReducerTests -only-testing:agentGuiTests/SessionExecutionRuntimeStateStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO`
2. 如果现有 VS Code task 可用，再运行 `Coordinator Runtime Tests` 任务，确认 focused runtime suite 没有隐藏的 derived data 依赖。
3. 搜索 `ConversationExecutionRuntimeCoordinator.swift`，确认不再出现 `projectionStore.projection(for:`。
4. 搜索 `ConversationExecutionRuntimeCoordinatorTests.swift`，确认新的 retention 判断主要基于 runtime state store，而不是 `projectionStore.setProjection(.fixture(...running...))`。

## 8. Risks and Guardrails

- 风险 1：如果为 runtime truth 再定义一套独立 lifecycle event，Feature 3 会和 Feature 4 重叠，造成双倍迁移成本。规避方式：先复用 `SessionExecutionProjectionEvent`。
- 风险 2：如果 orchestrator 直接调用 projection store 和 runtime state store 两次，未来很容易出现一边写成功一边漏写。规避方式：使用 fanout writer，保持单一 apply 入口。
- 风险 3：如果 coordinator 只把 `dispatch lease` 视为 protected provider refs，而没把运行中的 provider ref 合并进去，同 session provider 切换仍可能误杀旧 runtime。规避方式：显式为 running lease 写 focused test。
- 风险 4：如果测试仍然靠 `setProjection` 模拟 running 状态，Feature 3 的验收其实没有成立。规避方式：所有 retention-focused test 一律改用 runtime state fixture 或 runtime lifecycle event。
- 风险 5：如果 `ClaudeService` 和测试 harness 没有共享同一个 runtime state store，运行时行为可能在生产和测试中分叉。规避方式：把 store 提升到 service-level shared dependency，并在 harness 中显式构造。

## 9. Done Definition

Feature 3 可以关闭的标准：

1. `ConversationExecutionRuntimeCoordinator` 不再从 `ExecutionProjectionStore` 读取 running/provider 真值。
2. foreground、dispatch、running 三类 retention 优先级都在测试中被明确覆盖。
3. projection 滞后时，running runtime 不会被错误释放；finished runtime 也不会因为旧 projection 残留而继续保活。
4. `ConversationExecutionRecoveryTests` 能证明恢复链路会把 runtime truth store 恢复到正确状态。
5. 生产代码中 orchestrator 仍然只有一条 execution lifecycle 写口。

## 10. Execution Handoff

Plan complete and saved to `docs/plans/2026-03-29-runtime-retention-truth-source-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?