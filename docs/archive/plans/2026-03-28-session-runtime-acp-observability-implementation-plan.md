# Session Runtime / ACP Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current multi-store conversation execution stack with a session-journal-driven runtime platform that supports deletion-first runtime ownership, unified UI projection, ACP diagnostics, and structured telemetry.

**Architecture:** Introduce a per-session `SessionRuntimeActor` as the only execution truth holder, backed by append-only event records and reducer-derived projections. Move global fairness into a new `ExecutionAdmissionController`, split ACP transport/runtime work into a dedicated provider runtime actor, replace mutable projection caches with reducer outputs, and retire the legacy mailbox/controller/runtime coordinator stack.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing execution subsystem, existing ACP runtime subsystem, `OSLog`, `BusinessMonitor`, `PerformanceMonitor`, and the current reliability / diagnostics UI surface.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划应在独立 worktree 中执行；实现阶段使用 @executing-plans，逐 task 落地。
- 全程按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过，再提交。
- 删除优先，不保留兼容层；一旦新的 journal/runtime path 接管，就删除旧 controller / registry / mailbox / runtime coordinator 路径。
- 不要把 transport、恢复、attach、prompt 发送继续留在 `@MainActor`；主线程只保留 projection 发布和 UI 交互。
- 先锁回归面，再替换核心，再接 UI，再删旧代码；避免先改 UI 表象再追 runtime 问题。
- SwiftData 持久化和 reducer 内存投影必须拆开；UI 依赖 reducer，不依赖落盘完成。
- 所有跨 actor 数据必须是 `Sendable` DTO；不要把 live model 或 view state 直接跨隔离边界传递。
- 全部任务完成后，用 @requesting-code-review 做最终 review，重点检查：单一真值、actor 边界、ACP 诊断可见性、删除是否彻底。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionEventRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionTranscriptSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionDiagnosticsSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPFrameRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPSemanticRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TelemetryEnvelope.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionEventJournalStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionRuntimeActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionRuntimeCommandBus.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionAdmissionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionProjectionReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionDiagnosticsReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetryAPI.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetrySDK.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetryExporter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionDiagnosticsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/SessionDiagnosticsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionEventJournalStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionRuntimeActorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionAdmissionControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionProjectionReducerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDiagnosticsReducerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderRuntimeActorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TelemetryPipelineTests.swift`

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalUpdateProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PerformanceMonitor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposerExecutionPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRecoveryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPIsolationTests.swift`

### 必删文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionMailbox.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/LegacyConversationExecutionDriver.swift`

### 参考文档

- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-28-session-runtime-acp-observability-redesign.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-21-conversation-execution-runtime-rearchitecture-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-26-multi-session-parallel-execution-implementation-plan.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-27-dynamic-acp-provider-implementation-plan.md`

## 3. 里程碑顺序

1. 先锁定当前坏行为和目标回归面，避免重构后无法判断是否真的收敛状态源。
2. 再建立 journal 和 session runtime 真值模型，让并行、恢复、ACP 诊断先有统一输入。
3. 再引入 admission controller 和 provider runtime actor，替换 MainActor 运行时路径。
4. 然后把 UI projection 和 diagnostics 面板切到 reducer 输出。
5. 最后删除旧 controller / mailbox / legacy driver / runtime coordinator 语义，并做全量回归。

## 4. Task 1: 锁定删除前的行为基线

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRecoveryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPIsolationTests.swift`

**Step 1: Write the failing test**

补 5 组 characterization tests，锁定当前必须被新架构替换的行为：

- runtime 生命周期不应由 foreground selection 驱动。
- projection 不能依赖 controller/registry 手动同步。
- recovery 必须能从 durable 事件而不是 store 当前值恢复。
- ACP raw frame 和 semantic event 必须可按 session 追踪。
- 多 session 并行时，一个 session 的 runtime 关闭不能污染另一个 session。

```swift
@Test func foregroundSelectionDoesNotOwnRuntimeLifecycle() async throws {
    let harness = try RuntimeRetentionHarness.make()

    try await harness.startRunningAttempt(sessionID: "session-a")
    await harness.selectSession("session-b")

    #expect(await harness.runtimeStillRunning(sessionID: "session-a"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-1 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPIsolationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with current selection-coupled lifecycle, duplicated projection sync, or missing ACP diagnostics coverage.

**Step 3: Write minimal implementation**

只补测试 harness、spy exporter、ACP frame fixture；先不要改生产代码。

```swift
struct ACPFrameFixture {
    let sessionID: String
    let traceID: String
    let method: String
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for the new characterization tests.

**Step 5: Commit**

```bash
git add agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPIsolationTests.swift
git commit -m "test: lock session runtime redesign regressions"
```

## 5. Task 2: 建立 journal 记录和 snapshot 模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionEventRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionExecutionSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionTranscriptSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionDiagnosticsSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPFrameRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ACPSemanticRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TelemetryEnvelope.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionEventJournalStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionEventJournalStoreTests.swift`

**Step 1: Write the failing test**

Create `SessionEventJournalStoreTests.swift` covering:

- append 事件后 sequence 单调递增。
- `jobQueued -> jobStarted -> jobFinished` 能还原 execution snapshot。
- ACP frame 和 semantic event 可同时进入 diagnostics snapshot。
- 高频 transcript delta 允许异步批量写入，但核心 lifecycle 事件必须立即可读。

```swift
@Test func appendAssignsMonotonicSequencePerSession() async throws {
    let store = try SessionEventJournalStore.makeInMemory()

    let first = try await store.append(sessionID: "s1", category: .jobLifecycle, payload: .jobQueued(.fixture()))
    let second = try await store.append(sessionID: "s1", category: .jobLifecycle, payload: .jobStarted(.fixture()))

    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-2 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/SessionEventJournalStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing journal store, record models, or snapshot reducers.

**Step 3: Write minimal implementation**

- Add `SessionEventRecord` and typed payload envelope.
- Add in-memory `SessionEventJournalStore` append/query APIs.
- Add minimal snapshot rebuild helpers for execution and diagnostics.
- Extend `ExecutionPersistenceStore` to delegate durable lifecycle append calls into the journal store.

```swift
actor SessionEventJournalStore {
    func append(sessionID: String, category: EventCategory, payload: SessionEventPayload) async throws -> SessionEventRecord
    func records(sessionID: String) async -> [SessionEventRecord]
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for `SessionEventJournalStoreTests`.

**Step 5: Commit**

```bash
git add agentGui/Models/SessionEventRecord.swift agentGui/Models/SessionExecutionSnapshot.swift agentGui/Models/SessionTranscriptSnapshot.swift agentGui/Models/SessionDiagnosticsSnapshot.swift agentGui/Models/ACPFrameRecord.swift agentGui/Models/ACPSemanticRecord.swift agentGui/Models/TelemetryEnvelope.swift agentGui/Services/Execution/SessionEventJournalStore.swift agentGui/Services/Execution/ExecutionPersistenceStore.swift agentGuiTests/SessionEventJournalStoreTests.swift
git commit -m "feat: add session event journal foundation"
```

## 6. Task 3: 引入 SessionRuntimeActor 作为单一真值

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionRuntimeActor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionRuntimeCommandBus.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionRuntimeActorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRecoveryTests.swift`

**Step 1: Write the failing test**

Create `SessionRuntimeActorTests.swift` covering:

- `enqueue` 只向 journal append，不直接改 projection store。
- admitted 之后 runtime state 从 `cold` 进入 `warming/ready/attached/running`。
- cancel 只能结束当前 attempt，不会破坏其它 session 记录。
- `recoverFromJournal` 可以仅凭 journal 重建 snapshot。

```swift
@Test func recoverRebuildsQueueAndAttemptFromJournal() async throws {
    let harness = try SessionRuntimeHarness.makeRecovered()
    let snapshot = await harness.runtime.executionSnapshot

    #expect(snapshot.runningAttemptID != nil)
    #expect(snapshot.queuedJobIDs.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-3 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/SessionRuntimeActorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing `SessionRuntimeActor`, no journal-based recovery, or orchestrator still mutating projection state directly.

**Step 3: Write minimal implementation**

- Add `SessionRuntimeCommand` and `SessionRuntimeEvent` DTOs.
- Add `SessionRuntimeActor` with queue, running attempt, runtime state, attention state, and trace identity.
- Add `SessionRuntimeCommandBus` for session lookup and command routing.
- Make `ConversationExecutionOrchestrator` call command bus instead of directly mutating execution projection state.
- Make `RuntimeRecoveryService` rebuild runtime from journal replay.

```swift
enum SessionRuntimeCommand: Sendable {
    case enqueue(ExecutionRequestDraft)
    case admitted(jobID: UUID)
    case providerEvent(ProviderRuntimeEvent)
    case cancel(jobID: UUID?)
    case sessionViewed(Bool)
    case clearDiagnostics
    case recoverFromJournal
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for `SessionRuntimeActorTests` and updated recovery tests.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionRuntimeActor.swift agentGui/Services/Execution/SessionRuntimeCommandBus.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGui/Services/RuntimeRecoveryService.swift agentGuiTests/SessionRuntimeActorTests.swift agentGuiTests/ConversationExecutionRecoveryTests.swift
git commit -m "feat: add session runtime actor core"
```

## 7. Task 4: 用 ExecutionAdmissionController 替换 mailbox 扫描调度

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionAdmissionController.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionScheduler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionAdmissionControllerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionSchedulerTests.swift`

**Step 1: Write the failing test**

Create admission tests covering:

- 多 session 公平性，不允许单个 session 饥饿其它 session。
- provider capacity 与 interactive/background/recovery lane priority 同时生效。
- 单 session 默认只能有一个 active attempt。

```swift
@Test func controllerPrefersInteractiveJobWithoutStarvingOtherSessions() async throws {
    let controller = ExecutionAdmissionController(globalLimit: 2)

    await controller.enqueue(.fixture(sessionID: "A", priority: .interactive))
    await controller.enqueue(.fixture(sessionID: "A", priority: .interactive))
    await controller.enqueue(.fixture(sessionID: "B", priority: .interactive))

    let admitted = await controller.admitReadyJobs()
    #expect(admitted.map(\.sessionID).contains("B"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-4 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ExecutionAdmissionControllerTests -only-testing:agentGuiTests/ExecutionSchedulerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with mailbox-scan assumptions or missing admission controller.

**Step 3: Write minimal implementation**

- Add `ExecutionAdmissionController` actor with weighted fair queue.
- Shrink `ExecutionScheduler` to a thin compatibility wrapper or delete its policy logic once call sites are moved.
- Make orchestrator ask admission controller for grants, then send `.admitted(jobID:)` into the relevant session runtime actor.

```swift
actor ExecutionAdmissionController {
    func enqueue(_ request: AdmissionRequest) async
    func admitReadyJobs() async -> [AdmissionGrant]
    func markFinished(grantID: UUID) async
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for admission and scheduler tests.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ExecutionAdmissionController.swift agentGui/Services/Execution/ExecutionScheduler.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGuiTests/ExecutionAdmissionControllerTests.swift agentGuiTests/ExecutionSchedulerTests.swift
git commit -m "refactor: replace mailbox scheduling with admission controller"
```

## 8. Task 5: 抽离 ACPProviderRuntimeActor 和诊断记录链路

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPProviderRuntimeActor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPProviderRuntimeActorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ACPIsolationTests.swift`

**Step 1: Write the failing test**

Create ACP runtime tests covering:

- raw inbound/outbound frame capture produces `ACPFrameRecord` with sessionID, attemptID, traceID。
- semantic normalize 失败不会丢原始 frame。
- attach/new/load/prompt/cancel/close 全部通过 runtime actor 发回 typed provider events。
- provider base 不再需要在 `@MainActor` 上持有 transport state。

```swift
@Test func runtimeActorCapturesFrameBeforeNormalizationFailure() async throws {
    let harness = try ACPRuntimeHarness.make()

    try await harness.injectInboundFrame(method: "session/update", payload: .invalidJSON)

    let snapshot = await harness.diagnosticsSnapshot
    #expect(snapshot.frames.count == 1)
    #expect(snapshot.semanticErrors.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-5 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPProviderRuntimeActorTests -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPIsolationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing runtime actor, diagnostics persistence, or MainActor-coupled provider code.

**Step 3: Write minimal implementation**

- Add `ACPProviderRuntimeActor` owning process lifecycle, attach/load/new session, prompt send, cancel, close, and frame capture.
- Make `ACPExternalAgentRuntimeClient` emit typed transport events instead of directly driving UI-facing state.
- Restrict `ACPExternalExecutionProviderBase` to policy, capability checks, and event bridging into `SessionRuntimeActor`.
- Keep `ACPSessionRuntimeActor` only as runtime-handle / activation coordination if still needed; remove duplicated transport responsibilities.

```swift
actor ACPProviderRuntimeActor {
    func prepare(binding: ACPRemoteBindingSnapshot?) async throws
    func sendPrompt(_ request: ACPPromptRequest) async throws
    func cancelCurrentAttempt() async
    func close() async
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for ACP provider runtime, base provider, and isolation tests.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPProviderRuntimeActor.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPSessionRuntimeActor.swift agentGui/Services/ACP/ACPSessionRuntimeRegistry.swift agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift agentGuiTests/ACPProviderRuntimeActorTests.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPIsolationTests.swift
git commit -m "refactor: split acp provider runtime and diagnostics capture"
```

## 9. Task 6: 用 reducer 替换 execution projection cache 和 ACP update projector

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionProjectionReducer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionDiagnosticsReducer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionProjectionStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalUpdateProjector.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposerExecutionPresentation.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionProjectionReducerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDiagnosticsReducerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing test**

Create reducer tests covering:

- same journal 输入可稳定重建 `ComposerProjection`、`TranscriptProjection`、`DiagnosticsProjection`。
- ACP raw frame 不进入主聊天流，但会进入 diagnostics。
- attention / approval / user question 由 journal 派生，不再靠 controller 直接设值。

```swift
@Test func diagnosticsProjectionKeepsFramesOutOfTranscript() {
    let projections = SessionProjectionReducer.reduce(records: .fixtureWithACPFrames())

    #expect(projections.transcript.debugLines.isEmpty)
    #expect(projections.diagnostics.frames.count == 2)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-6 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/SessionProjectionReducerTests -only-testing:agentGuiTests/SessionDiagnosticsReducerTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing reducer store or legacy projection cache assumptions.

**Step 3: Write minimal implementation**

- Add reducer layer that folds journal records into the three projection snapshots.
- Replace `ExecutionProjectionStore` call sites with a new read-only `SessionProjectionStore` that publishes reducer output.
- Strip `ACPExternalUpdateProjector` down to a temporary bridge or delete it once reducer-driven UI is wired.
- Move turn phase into `SessionRuntimeActor` state; stop relying on `ACPExternalSessionTurnRouter` for core truth.

```swift
struct SessionProjectionBundle: Sendable {
    let composer: SessionExecutionSnapshot
    let transcript: SessionTranscriptSnapshot
    let diagnostics: SessionDiagnosticsSnapshot
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for reducer and presentation tests.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/SessionProjectionReducer.swift agentGui/Services/Execution/SessionDiagnosticsReducer.swift agentGui/Services/Execution/SessionProjectionStore.swift agentGui/Models/ExecutionProjection.swift agentGui/Services/ACP/ACPExternalUpdateProjector.swift agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift agentGui/Views/ChatComposerExecutionPresentation.swift agentGuiTests/SessionProjectionReducerTests.swift agentGuiTests/SessionDiagnosticsReducerTests.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift
git commit -m "refactor: derive execution and diagnostics projections from journal"
```

## 10. Task 7: 接入聊天 UI 和 diagnostics 工作台

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionDiagnosticsViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/SessionDiagnosticsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing test**

补 UI-level tests 覆盖：

- 主聊天流只显示 transcript projection，不显示 raw ACP debug 文本。
- blocked / approval / user question 状态显示在 composer 和 diagnostics，不混进 transcript。
- diagnostics 面板可过滤 frame direction、method、attempt。

```swift
@Test func chatMessageListHidesRawACPFrames() {
    let projection = SessionProjectionBundle.fixtureWithACPFrames()
    let model = ChatMessageListPresentation.make(from: projection)

    #expect(model.visibleDebugFrames == 0)
    #expect(model.theaterCard != nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-7 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with ChatView still reading legacy execution state or no diagnostics panel model.

**Step 3: Write minimal implementation**

- Add `SessionDiagnosticsViewModel` that consumes `SessionProjectionStore`.
- Add `SessionDiagnosticsView` with timeline, ACP frame list, semantic event list, and metrics summary.
- Update chat views to read reducer output only.
- Expose diagnostics entry from `ReliabilityCenterView` and `WorkbenchShellView`.

```swift
@MainActor
final class SessionDiagnosticsViewModel: ObservableObject {
    @Published private(set) var projection: SessionDiagnosticsSnapshot
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for updated chat presentation tests.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/SessionDiagnosticsViewModel.swift agentGui/Views/Reliability/SessionDiagnosticsView.swift agentGui/Views/ChatView.swift agentGui/Views/ChatView+MessageList.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGui/Views/Workbench/WorkbenchShellView.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift
git commit -m "feat: wire journal projections into chat and diagnostics UI"
```

## 11. Task 8: 建立统一 telemetry pipeline 并替换 print 路径

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetryAPI.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetrySDK.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Telemetry/TelemetryExporter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/BusinessMonitor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/PerformanceMonitor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TelemetryPipelineTests.swift`

**Step 1: Write the failing test**

Create telemetry tests covering:

- trace/log/metric 共享同一个 correlation identity。
- `queue.wait`、`runtime.attach`、`provider.first_event`、`projection.reduce` 会生成 span。
- 默认 exporter 写入 `OSLog` 与 in-memory sink；核心路径不再调用 `print`。

```swift
@Test func spansAndLogsShareAttemptTraceID() async throws {
    let harness = TelemetryHarness()
    try await harness.emitAttemptLifecycle()

    #expect(harness.exportedSpans.allSatisfy { $0.traceID == harness.traceID })
    #expect(harness.exportedLogs.allSatisfy { $0.traceID == harness.traceID })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-8 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/TelemetryPipelineTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing telemetry API/SDK or direct `print` usage still required.

**Step 3: Write minimal implementation**

- Add `TelemetryAPI`, `TelemetrySDK`, and exporter protocols.
- Make `BusinessMonitor` a thin business-event emitter on top of telemetry API.
- Make `PerformanceMonitor` emit spans/metrics only; remove stdout printing.
- Register telemetry in `agentGuiApp` and pass it into runtime / ACP entry points.

```swift
protocol TelemetryExporter: Sendable {
    func export(spans: [TelemetrySpan]) async
    func export(logs: [TelemetryLog]) async
    func export(metrics: [TelemetryMetric]) async
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for `TelemetryPipelineTests`.

**Step 5: Commit**

```bash
git add agentGui/Services/Telemetry/TelemetryAPI.swift agentGui/Services/Telemetry/TelemetrySDK.swift agentGui/Services/Telemetry/TelemetryExporter.swift agentGui/Utilities/BusinessMonitor.swift agentGui/Utilities/PerformanceMonitor.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/agentGuiApp.swift agentGuiTests/TelemetryPipelineTests.swift
git commit -m "refactor: add unified telemetry pipeline"
```

## 12. Task 9: 删除旧执行栈并收口到新入口

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionController.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionRegistry.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/SessionExecutionMailbox.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/BuiltInSessionExecutionRegistry.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/LegacyConversationExecutionDriver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ConversationExecutionRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionRegistryTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionExecutionControllerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BuiltInSessionExecutionRegistryTests.swift`

**Step 1: Write the failing test**

把旧测试改成“删除证明”型测试：

- app 组合根只注册 command bus、journal store、projection store、telemetry，不再注册旧 controller/registry。
- runtime coordinator 只保留新 pin/ttl policy 或直接被更小的 helper 替代。
- 删除旧文件后没有 dangling dependency。

```swift
@Test func appCompositionDoesNotBuildLegacyExecutionRegistry() throws {
    let graph = AppCompositionHarness.make()
    #expect(graph.legacyExecutionRegistry == nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-9 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/SessionExecutionRegistryTests -only-testing:agentGuiTests/SessionExecutionControllerTests -only-testing:agentGuiTests/BuiltInSessionExecutionRegistryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with remaining legacy registration, imports, or test fixtures still depending on deleted files.

**Step 3: Write minimal implementation**

- Remove the five legacy execution files.
- Collapse `ConversationExecutionRuntimeCoordinator` into pin/ttl policy helper or remove its old lease semantics from all call sites.
- Update app composition to instantiate only journal store, command bus, session runtime, admission controller, projection store, telemetry, and diagnostics view model dependencies.

```swift
struct RuntimePinPolicy: Sendable {
    let warmTTL: Duration
    let recoveryTTL: Duration
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS with no references to deleted execution layers.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete legacy execution runtime layers"
```

## 13. Task 10: 全量回归和文档收尾

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-28-session-runtime-acp-observability-redesign.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`

**Step 1: Write the failing test**

这里不新增产品测试，改为先定义必须通过的回归命令清单，并把每条命令的预期写进变更说明：

- session runtime actor focused tests
- ACP provider focused tests
- recovery focused tests
- command platform focused tests

```text
Required test matrix must pass before merge.
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-10 -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/SessionRuntimeActorTests -only-testing:agentGuiTests/ExecutionAdmissionControllerTests -only-testing:agentGuiTests/SessionProjectionReducerTests -only-testing:agentGuiTests/SessionDiagnosticsReducerTests -only-testing:agentGuiTests/ACPProviderRuntimeActorTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS. If any test fails, do not merge.

Then run existing broader suites:

```bash
xcodebuild test -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-redesign-plan-10b -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPIsolationTests -only-testing:agentGuiTests/ExecutionSchedulerTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 3: Write minimal implementation**

- Update the technical spec status section with implementation outcomes and any scope cuts.
- Add a short README note for the new execution platform, diagnostics panel, and telemetry architecture entry points.

```markdown
## Session Runtime Platform

Execution truth now lives in `SessionRuntimeActor` and `SessionEventJournalStore`.
```

**Step 4: Run test to verify it passes**

Re-run both `xcodebuild` commands above.

Expected: PASS for all listed suites.

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-28-session-runtime-acp-observability-redesign.md README.md
git commit -m "docs: finalize session runtime redesign rollout"
```

## 14. 执行注意点

- 如果 `ConversationExecutionRuntimeCoordinator.swift` 无法干净瘦身，就直接删除并以更小的 `RuntimePinPolicy` + command bus 替代，不要保留半废弃 lease 模型。
- 如果 `ExecutionProjectionStore.swift` 仍有大量调用方，先把它改成对 `SessionProjectionStore` 的只读 facade，再在 Task 9 一次性删除旧写接口。
- 如果 ACP raw payload 过大，不要把完整正文默认进 journal；只保留 preview、size、hash、redaction 状态。
- 如果 SwiftData journal 写入成为瓶颈，优先增加 writer actor 和批量策略，不要回退到 controller 本地缓存。
- 如果 UI 需要更细粒度刷新，优化 reducer batching，不要把临时状态重新塞回 view 或 provider base。

## 15. 合并门槛

- 所有新增 focused tests 通过。
- 旧执行层文件已删除，且不存在新的 compatibility wrapper。
- `@MainActor` 不再承载 ACP transport 或运行时 attach/prompt 路径。
- 主聊天流不再展示 raw ACP debug 文本。
- diagnostics 面板可以按 session 查看 ACP frame、semantic event、runtime metrics。
- telemetry spans / logs / metrics 具备统一 trace identity。

Plan complete and saved to `docs/plans/2026-03-28-session-runtime-acp-observability-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?