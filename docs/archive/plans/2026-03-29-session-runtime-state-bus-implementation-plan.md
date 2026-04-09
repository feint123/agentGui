# Session Runtime State Bus Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Establish a unified session runtime event and snapshot bus so orchestrator, runtime coordinator, UI projection, recovery summary, and diagnostics all derive from the same per-session runtime truth.

**Architecture:** Promote the current lifecycle-event fanout into a first-class session runtime bus with a reducer-backed `SessionRuntimeSnapshot` store. `ConversationExecutionOrchestrator` remains the only lifecycle producer, but it now emits runtime events into a shared bus; `ExecutionProjectionStore`, `ConversationExecutionRuntimeCoordinator`, `RuntimeRecoveryService`, and a minimal diagnostics presentation all subscribe to the same snapshot source instead of maintaining parallel execution-state copies.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing execution subsystem (`ConversationExecutionOrchestrator`, `ExecutionProjectionStore`, `ConversationExecutionRuntimeCoordinator`, `RuntimeRecoveryService`, `ClaudeService`, Reliability Center).

---

## 1. Implementation Rules

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 4，不提前实现 Feature 5 的恢复异步化、Feature 8 的 ACP session actor 化、Feature 9 的完整 observability 平台。
- 严格按 @test-driven-development 执行：每个 task 先写失败测试，再验证红灯，再写最小实现，再跑通过，再提交。
- `ConversationExecutionOrchestrator` 继续是唯一 lifecycle 生产者；不要让 `RuntimeRecoveryService`、`ExecutionProjectionStore` 或 diagnostics 侧反向生成运行态事件。
- 不要再保留“projection event 一套、runtime state 一套、recovery 再扫一次”的三套真值。Feature 4 完成后，至少 execution 维度必须只剩一份 session runtime snapshot。
- `presentationChanged` 这类纯 UI 事件不属于 runtime truth；保留为 UI projection 私有派生，不要把它混入 session runtime bus。
- `cancel` 在 Feature 4 中必须成为显式 runtime 事件，而不是只依赖最终 `.finished(outcome: .cancelled)`；否则 recovery 和 diagnostics 无法表达“取消已请求但尚未收敛”。
- Reliability Center 已经是现有 diagnostics 承载点；Feature 4 只需补一个最小 runtime 状态 section，不要在本轮扩张成完整 trace 浏览器。
- focused tests 必须显式覆盖“同一 snapshot 被 projection、runtime coordinator、recovery summary 同时看见”的场景，避免继续依赖共享多个 store 或隐式注入顺序。
- 回归完成后，用 @requesting-code-review 做一次 focused review，重点检查：单一 snapshot 真值是否成立、cancel 事件是否完整、recovery 是否停止绕过 bus、Feature 3 新增的 runtime state sidecar 是否已经收敛或删除。

## 2. Current State Summary

- `ConversationExecutionOrchestrator` 目前只会发 `SessionExecutionProjectionEvent`，并通过 `SessionExecutionLifecycleFanoutWriter` 同步更新 `ExecutionProjectionStore` 与 `SessionExecutionRuntimeStateStore`。
- `SessionExecutionRuntimeStateStore` 只是 Feature 3 的 sidecar store，字段只够 runtime retention 使用，不能表达取消中、恢复来源、最近迁移动作或 diagnostics 摘要。
- `ExecutionProjectionStore` 仍然直接以 lifecycle event 为输入，而不是以统一 snapshot 为输入，所以 projection 与 runtime state 只是“从同一事件并行归约”，还不是“从同一 snapshot 派生”。
- `RuntimeRecoveryService` 完全绕过 execution lifecycle，总是扫描 `Message` / `RecoverySnapshot`，因此启动恢复后的 recovery UI 与 runtime coordinator 看到的不是同一份运行时状态。
- Reliability Center 目前只展示数据完整性、恢复项和持久化失败，没有 session runtime diagnostics section；这意味着 Feature 4 需要先补一个最小派生入口，Feature 9 再扩成完整事件链路。
- `ConversationExecutionRecoveryTests` 和 `ConversationExecutionRuntimeCoordinatorTests` 已经开始共享 runtime state store，但 recovery summary 仍不依赖它，这说明 Feature 3 只完成了 retention 真值下沉，还没形成跨模块 bus。

## 3. Desired End State

完成后应满足以下条件：

1. `ConversationExecutionOrchestrator` 为 enqueue、recover、start、cancelRequested、finish、prune 发出统一 `SessionRuntimeEvent`。
2. `SessionRuntimeSnapshotStore` 成为 execution runtime 的唯一会话级真值容器，`snapshot(for:)` 返回的 DTO 同时满足 runtime coordinator、projection adapter、recovery summary、diagnostics summary 的读取需求。
3. `ExecutionProjectionStore` 不再直接消费 orchestrator 发出的 event；它改为消费 `SessionRuntimeSnapshot`，并只在 projection 私有字段上叠加 `presentationChanged` 之类 UI 派生状态。
4. `ConversationExecutionRuntimeCoordinator` 读取的类型从 `SessionExecutionRuntimeState` 升级为 `SessionRuntimeSnapshot`，不再关心 projection 是否先发布。
5. `RuntimeRecoveryService` 能从 `SessionRuntimeSnapshotStore` 派生 execution recovery 项，保证启动恢复后聊天页和 Reliability Center 看到的运行态与 runtime coordinator 一致。
6. Reliability Center 新增最小 runtime 状态 section，至少能显示 session、activity、provider、queued count、是否 cancelling、最近一次 lifecycle action。
7. Feature 3 引入的 `SessionExecutionRuntimeState*` 类型若不再需要，应在本轮删除；如果暂时保留，也必须退化为 `SessionRuntimeSnapshot` 的兼容包装，而不是第二套真值。

## 4. Target Files

### New production files

- `agentGui/Services/Execution/SessionRuntimeEvent.swift`
- `agentGui/Services/Execution/SessionRuntimeSnapshot.swift`
- `agentGui/Services/Execution/SessionRuntimeSnapshotReducer.swift`
- `agentGui/Services/Execution/SessionRuntimeSnapshotStore.swift`
- `agentGui/Services/Execution/SessionRuntimeBus.swift`
- `agentGui/Services/Execution/SessionRuntimeProjectionAdapter.swift`
- `agentGui/Services/Execution/SessionRuntimeDiagnosticsSnapshot.swift`

### Production files to modify

- `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `agentGui/Services/Execution/SessionExecutionProjectionReducer.swift`
- `agentGui/Services/Execution/SessionExecutionProjectionEvent.swift`
- `agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift`
- `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- `agentGui/Services/RuntimeRecoveryService.swift`
- `agentGui/Services/ClaudeService/ClaudeService.swift`
- `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- `agentGui/Views/ChatView.swift`
- `agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- `agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `agentGui/agentGuiApp.swift`

### Production files likely to delete or collapse

- `agentGui/Services/Execution/SessionExecutionRuntimeState.swift`
- `agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift`
- `agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift`

### Test files to create

- `agentGuiTests/SessionRuntimeSnapshotReducerTests.swift`
- `agentGuiTests/SessionRuntimeSnapshotStoreTests.swift`
- `agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift`
- `agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests.swift`

### Test files to modify

- `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- `agentGuiTests/ExecutionProjectionStoreTests.swift`
- `agentGuiTests/SessionExecutionProjectionReducerTests.swift`
- `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`

## 5. Task Breakdown

### Task 1: 定义统一 runtime event 和 snapshot 合约

**Files:**
- Create: `agentGui/Services/Execution/SessionRuntimeEvent.swift`
- Create: `agentGui/Services/Execution/SessionRuntimeSnapshot.swift`
- Create: `agentGui/Services/Execution/SessionRuntimeSnapshotReducer.swift`
- Create: `agentGuiTests/SessionRuntimeSnapshotReducerTests.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionProjectionEvent.swift`

**Step 1: Write the failing tests**

新增纯 reducer 测试，至少锁定以下行为：

- `enqueue` 把 job 追加到 `queuedJobIDs` 并记录 `lastAction = .enqueued`
- `start` 把 job 迁移为 `runningJobID` 并记录 `runningProviderReference`
- `recover` 在同一 reducer 中重建 queued/running 状态，并标记 `lastAction = .recovered`
- `cancelRequested` 不清空运行中 job，但把 snapshot 标成 cancelling
- `finish(cancelled)` 清空 running/cancelling 状态，并保留剩余队列
- `prune` 只更新队列，不污染运行中字段

建议测试骨架：

```swift
import Foundation
import Testing
@testable import agentGui

struct SessionRuntimeSnapshotReducerTests {
    @Test
    func cancelRequestedMarksRunningSnapshotAsCancelling() {
        let runningJobID = UUID()
        let current = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [],
            lastAction: .started,
            lastUpdatedAt: .distantPast
        )

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: current,
            event: .cancelRequested(sessionID: "session-a", jobID: runningJobID)
        )

        #expect(reduced.isRunning)
        #expect(reduced.isCancelling)
        #expect(reduced.requestedCancellationJobIDs == [runningJobID])
        #expect(reduced.lastAction == .cancelRequested)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task1 -only-testing:agentGuiTests/SessionRuntimeSnapshotReducerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the runtime bus contract does not exist yet.

**Step 3: Write minimal implementation**

新增统一类型，并把现有 `SessionExecutionProjectionEvent` 迁移为更宽的 runtime 事件定义。推荐事件集合：

```swift
enum SessionRuntimeEvent: Sendable, Equatable {
    case enqueued(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case recovered(sessionID: String, queuedJobIDs: [UUID], runningJobID: UUID?, providerReference: ExecutionProviderReference?)
    case started(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case cancelRequested(sessionID: String, jobID: UUID)
    case finished(sessionID: String, jobID: UUID, outcome: ExecutionJobState)
    case pruned(sessionID: String, jobID: UUID)
}
```

snapshot 至少需要包含：

- `sessionID`
- `queuedJobIDs`
- `runningJobID`
- `runningProviderReference`
- `requestedCancellationJobIDs`
- `lastAction`
- `lastUpdatedAt`

如果实现上需要平滑迁移，可以短期保留 `typealias SessionExecutionProjectionEvent = SessionRuntimeEvent`，但不要保留两套 reducer 真值。

**Step 4: Run tests to verify they pass**

Run 同 Step 2。

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionRuntimeEvent.swift agentGui/Services/Execution/SessionRuntimeSnapshot.swift agentGui/Services/Execution/SessionRuntimeSnapshotReducer.swift agentGui/Services/Execution/SessionExecutionProjectionEvent.swift agentGuiTests/SessionRuntimeSnapshotReducerTests.swift
git commit -m "feat: define session runtime event and snapshot contract"
```

### Task 2: 建立共享 snapshot store 和 bus 写口

**Files:**
- Create: `agentGui/Services/Execution/SessionRuntimeSnapshotStore.swift`
- Create: `agentGui/Services/Execution/SessionRuntimeBus.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift`
- Modify: `agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift`
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Messaging.swift`
- Modify: `agentGui/agentGuiApp.swift`
- Create: `agentGuiTests/SessionRuntimeSnapshotStoreTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing tests**

补两组测试：

1. store 测试，确认同一个 runtime event 会更新 `snapshot(for:)`，且 cancel 事件不会丢失；
2. recovery harness 测试，确认 orchestrator 在 enqueue/start/finish/cancel 路径都只通过一个 bus sink 发事件，测试不需要额外拼多个共享 store。

建议测试骨架：

```swift
@Test
func busPublishesSnapshotAfterCancelRequest() {
    let store = SessionRuntimeSnapshotStore()
    let bus = SessionRuntimeBus(store: store)
    let jobID = UUID()

    bus.publish(.started(sessionID: "session-a", jobID: jobID, providerReference: .builtIn))
    bus.publish(.cancelRequested(sessionID: "session-a", jobID: jobID))

    let snapshot = store.snapshot(for: "session-a")
    #expect(snapshot.isRunning)
    #expect(snapshot.isCancelling)
}
```

在 `ConversationExecutionRecoveryTests` 增加一条集成断言：`restorePendingJobs()` 后，projection、runtime coordinator 输入、recovery summary 输入都读取同一个 `SessionRuntimeSnapshotStore`。

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task2 -only-testing:agentGuiTests/SessionRuntimeSnapshotStoreTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because no shared snapshot store / bus exists yet.

**Step 3: Write minimal implementation**

推荐把 bus 设计为“单写入口 + 多消费快照”，而不是把多个 reducer 直接绑在 orchestrator 上：

```swift
@MainActor
final class SessionRuntimeBus {
    private let store: SessionRuntimeSnapshotStore

    init(store: SessionRuntimeSnapshotStore) {
        self.store = store
    }

    func publish(_ event: SessionRuntimeEvent) {
        store.apply(event)
    }

    func snapshot(for sessionID: String) -> SessionRuntimeSnapshot {
        store.snapshot(for: sessionID)
    }
}
```

`ConversationExecutionOrchestrator` 改动重点：

- `enqueue` 发布 `.enqueued`
- `restorePendingJobs` 发布 `.recovered`
- `dispatch` 发布 `.started`
- `cancelRunning` 先发布 `.cancelRequested`，再触发 driver cancel
- `finish` 发布 `.finished`
- `pruneInvalidQueuedJob` 继续发布 `.pruned`

`ClaudeService` 和应用启动路径统一注入同一个 `SessionRuntimeSnapshotStore` / `SessionRuntimeBus`，不再在不同 harness 里各自 new 一个 sidecar store。

**Step 4: Run tests to verify they pass**

Run 同 Step 2。

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionRuntimeSnapshotStore.swift agentGui/Services/Execution/SessionRuntimeBus.swift agentGui/Services/Execution/SessionExecutionLifecycleFanoutWriter.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/ClaudeService/ClaudeService.swift agentGui/Services/ClaudeService/ClaudeService+Messaging.swift agentGui/agentGuiApp.swift agentGuiTests/SessionRuntimeSnapshotStoreTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "feat: route execution lifecycle through session runtime bus"
```

### Task 3: 让 projection 和 runtime coordinator 都从 snapshot 派生

**Files:**
- Create: `agentGui/Services/Execution/SessionRuntimeProjectionAdapter.swift`
- Modify: `agentGui/Services/Execution/ExecutionProjectionStore.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionProjectionReducer.swift`
- Modify: `agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionRuntimeState.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift`
- Modify: `agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `agentGuiTests/SessionExecutionProjectionReducerTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`

**Step 1: Write the failing tests**

增加两类测试：

1. projection adapter tests，确认相同 snapshot 可以生成 queued/running/idle 三种 projection；
2. runtime coordinator tests，确认它只读取 snapshot store，projection 即使滞后，retention 仍以 snapshot 为准。

建议在 `ConversationExecutionRuntimeCoordinatorTests` 新增一条更直接的断言：

```swift
@Test
func runtimeCoordinatorIgnoresProjectionWhenSnapshotStillRunning() async throws {
    let snapshotStore = SessionRuntimeSnapshotStore()
    let coordinator = ConversationExecutionRuntimeCoordinator(runtimeSnapshotStore: snapshotStore)
    let runningJobID = UUID()

    snapshotStore.apply(.started(sessionID: "session-a", jobID: runningJobID, providerReference: .builtIn))

    // projection side intentionally not updated here
    #expect(snapshotStore.snapshot(for: "session-a").isRunning)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task3 -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/SessionExecutionProjectionReducerTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because projection store still reduces raw lifecycle events and coordinator still depends on Feature 3 sidecar types.

**Step 3: Write minimal implementation**

做三件事，顺序不要乱：

1. 新增 `SessionRuntimeProjectionAdapter`，把 `SessionRuntimeSnapshot` 映射到 `SessionExecutionProjection` 的 execution 字段；
2. `ExecutionProjectionStore` 改成持有 projection dictionary，但其 execution 相关更新入口变成 `apply(snapshot:)`；
3. `ConversationExecutionRuntimeCoordinator` 的注入从 `SessionExecutionRuntimeStateStore` 升级成 `SessionRuntimeSnapshotStore`，内部只读取 snapshot。

`presentationChanged` 建议保留在 `ExecutionProjectionStore` 内部，以免把 UI 状态反推回 runtime truth：

```swift
func apply(runtimeSnapshot: SessionRuntimeSnapshot) {
    let current = projection(for: runtimeSnapshot.sessionID)
    projections[runtimeSnapshot.sessionID] = SessionRuntimeProjectionAdapter.project(
        current: current,
        runtimeSnapshot: runtimeSnapshot
    )
}
```

如果 Feature 3 的 `SessionExecutionRuntimeState*` 已经被完全替代，直接删除；如果当前迁移量太大，可先把它们改成 `SessionRuntimeSnapshot` 的兼容 alias，但必须保证仓库中不再有第二套独立 reducer。

**Step 4: Run tests to verify they pass**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionRuntimeProjectionAdapter.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGui/Services/Execution/SessionExecutionProjectionReducer.swift agentGui/Services/ConversationExecutionRuntimeCoordinator.swift agentGui/Services/Execution/SessionExecutionRuntimeState.swift agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/SessionExecutionProjectionReducerTests.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift
git commit -m "refactor: derive projection and retention from runtime snapshots"
```

### Task 4: 让 recovery summary 和 diagnostics panel 消费同一 snapshot

**Files:**
- Create: `agentGui/Services/Execution/SessionRuntimeDiagnosticsSnapshot.swift`
- Modify: `agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- Modify: `agentGui/Views/Reliability/ReliabilityCenterView.swift`
- Modify: `agentGui/Views/ChatView.swift`
- Create: `agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift`
- Create: `agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests.swift`

**Step 1: Write the failing tests**

补两组单测：

1. `RuntimeRecoveryServiceRuntimeSnapshotTests`，确认 running / queued / cancelling snapshot 会派生出对应 recovery summary；
2. `SessionRuntimeDiagnosticsSnapshotTests`，确认 diagnostics 展示字段来自 snapshot，而不是直接读 projection 或扫描 SwiftData。

建议 recovery 测试骨架：

```swift
@Test
func recoverySummaryUsesRuntimeSnapshotForQueuedAndRunningSessions() {
    let store = SessionRuntimeSnapshotStore()
    let service = RuntimeRecoveryService(runtimeSnapshotStore: store, persistenceCoordinator: .shared)
    let runningJobID = UUID()

    store.apply(.recovered(
        sessionID: "session-a",
        queuedJobIDs: [UUID(), runningJobID],
        runningJobID: runningJobID,
        providerReference: .builtIn
    ))

    let items = service.runtimeRecoveryItems(for: "session-a")
    #expect(items.isEmpty == false)
    #expect(items.first?.sessionID == "session-a")
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task4 -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests -only-testing:agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because recovery service and Reliability Center do not yet read the runtime snapshot store.

**Step 3: Write minimal implementation**

实现策略保持克制：

- `RuntimeRecoveryService` 保留现有 SwiftData `RecoverySnapshot` 逻辑，但新增一层 runtime-derived summary 输出，例如 `runtimeRecoveryItems(for:)` 或统一的 `recoveryPresentation(for:)`；
- runtime-derived items 只覆盖 execution lifecycle 维度，不碰 Feature 5 的异步增量化；
- Reliability Center 增加一个 “Session Runtime” section，展示 `SessionRuntimeDiagnosticsSnapshot` 列表；
- `ChatView` 的恢复/运行态提示若需要合并，优先读取 `RuntimeRecoveryService` 的统一 presentation，而不是直接扫描 model。

推荐 diagnostics DTO：

```swift
struct SessionRuntimeDiagnosticsSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let sessionID: String
    let activityText: String
    let providerText: String
    let queuedCount: Int
    let isCancelling: Bool
    let lastActionText: String
}
```

**Step 4: Run tests to verify they pass**

Run 同 Step 2，然后补跑 recovery focused suite：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task4b -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionRuntimeDiagnosticsSnapshot.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/ViewModels/ReliabilityCenterViewModel.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGui/Views/ChatView.swift agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "feat: derive recovery and diagnostics from runtime snapshots"
```

### Task 5: 收敛测试夹具并删除 sidecar 真值

**Files:**
- Modify: `agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift`
- Modify: `agentGuiTests/ConversationExecutionRecoveryTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Delete or collapse: `agentGui/Services/Execution/SessionExecutionRuntimeState.swift`
- Delete or collapse: `agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift`
- Delete or collapse: `agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift`

**Step 1: Write the failing tests**

在 focused tests 中增加一条明确验收用例：不共享多个 projection store，只共享一个 `SessionRuntimeSnapshotStore` 仍然可以同时满足 projection、runtime coordinator、recovery summary 断言。

建议命名：

- `singleRuntimeSnapshotStoreDrivesProjectionRetentionAndRecovery`

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task5 -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until fixtures and old sidecar types are fully removed from the test harness.

**Step 3: Write minimal implementation**

- 所有 harness 统一显式注入 `SessionRuntimeSnapshotStore`
- projection store 只作为 snapshot 派生结果观察面存在，不再承担 runtime 真值角色
- 删除 Feature 3 sidecar 类型，或在最后一次迁移后把所有外部引用收口到 snapshot store

不要留下这种状态：

- coordinator 用 `SessionRuntimeSnapshotStore`
- recovery 用另一份 `SessionExecutionRuntimeStateStore`
- projection tests 继续人工 `setProjection(.fixture(...))` 当成 runtime 真值

**Step 4: Run tests to verify they pass**

Run 同 Step 2，然后跑完整 focused command：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-task5b -only-testing:agentGuiTests/SessionRuntimeSnapshotReducerTests -only-testing:agentGuiTests/SessionRuntimeSnapshotStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests -only-testing:agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/TestSupport/MultiSessionExecutionFixtures.swift agentGuiTests/ConversationExecutionRecoveryTests.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGui/Services/Execution/SessionExecutionRuntimeState.swift agentGui/Services/Execution/SessionExecutionRuntimeStateReducer.swift agentGui/Services/Execution/SessionExecutionRuntimeStateStore.swift
git commit -m "refactor: consolidate execution runtime truth into snapshot bus"
```

## 6. Validation Checklist

全部任务完成后，按顺序验证：

1. `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-bus-final -only-testing:agentGuiTests/SessionRuntimeSnapshotReducerTests -only-testing:agentGuiTests/SessionRuntimeSnapshotStoreTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests -only-testing:agentGuiTests/SessionRuntimeDiagnosticsSnapshotTests CODE_SIGNING_ALLOWED=NO`
2. 如果现有 task 可用，再运行 `Coordinator Runtime Tests`，确认 runtime coordinator focused suite 不依赖旧 sidecar store。
3. 搜索 `ConversationExecutionRuntimeCoordinator.swift`，确认不再出现 `SessionExecutionRuntimeStateStore`。
4. 搜索 `RuntimeRecoveryService.swift`，确认 execution 维度 recovery summary 已经读取 `SessionRuntimeSnapshotStore` 或等价总线，而不是只依赖 `Message.status == .pending`。
5. 搜索 `ConversationExecutionOrchestrator.swift`，确认 `cancelRunning` 已显式发布 `cancelRequested` 事件。
6. 搜索仓库，确认不存在第二套 execution runtime reducer 真值路径；若 `SessionExecutionRuntimeState*` 仍存在，它们必须只是兼容 alias 或 adapter。

## 7. Risks and Guardrails

- 风险 1：如果 Feature 4 继续复用 `SessionExecutionProjectionEvent` 名称但偷偷扩展语义，后续很容易让 projection-only 逻辑再次污染 runtime bus。规避方式：尽早引入清晰命名的 `SessionRuntimeEvent`。
- 风险 2：如果 `cancelRequested` 不进入 snapshot，Reliability Center 和 recovery summary 只能看到“仍在 running”或“已经 cancelled”，中间态会丢失。规避方式：把取消显式建模为 runtime snapshot 字段。
- 风险 3：如果 projection store 仍直接 reduce raw event，而 recovery / coordinator 读取 snapshot，那么系统又会回到“同事件、不同派生入口”的并行模型。规避方式：Feature 4 完成后，projection 必须从 snapshot 派生。
- 风险 4：如果在本轮把 recovery service 彻底改成异步后台 actor，会和 Feature 5 范围重叠。规避方式：Feature 4 只改 recovery truth source，不改异步化策略。
- 风险 5：如果为了兼容测试保留两个 store 并手工同步，验收标准 3 会再次失效。规避方式：测试夹具只允许显式共享 `SessionRuntimeSnapshotStore` 一份真值。

## 8. Handoff Notes

- 实现顺序不要反过来。先定 contract 和 store，再迁 orchestrator，再迁 projection/coordinator，最后接 recovery 和 diagnostics。
- 每做完一个 task 都重新搜索一次 `SessionExecutionRuntimeState`、`SessionExecutionProjectionEvent`、`setProjection(`，确认没有把旧模型悄悄带回去。
- 如果中途发现 `RuntimeRecoveryService` 的现有 UI API 不适合承接 runtime-derived items，优先新增一个小 presentation DTO，不要为了复用旧 `RecoverySnapshot` 强行把 snapshot 总线重新落到 SwiftData。