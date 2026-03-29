# Runtime Recovery Async Incremental Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move persisted recovery-summary refresh off the main thread and make it incremental, batched, and proportional to unresolved recovery work instead of total history size.

**Architecture:** Keep `RuntimeRecoveryService` as the `@MainActor` presentation facade, but push SwiftData fetch/diff/upsert work into a dedicated background recovery coordinator that owns its own `ModelContext` lifecycle. Use Feature 4's `SessionRuntimeSnapshotStore` for live execution recovery, add explicit incremental source events for persisted message/task recovery, and publish only value-type recovery presentation DTOs back to the UI so chat bootstrap no longer blocks on a synchronous full scan.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Swift Testing, existing execution runtime bus (`SessionRuntimeSnapshotStore`), `ExecutionPersistenceStore`, `BackgroundTaskObservationService`, and repo smoke scripts under `scripts/`.

---

## 1. Implementation Rules

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 5，不提前实现 Feature 6 的消息列表后台投影，也不把 ACP provider session actor 化提前拉进本轮。
- 严格按 @test-driven-development 执行：每个 task 先写失败测试，再验证红灯，再写最小实现，再跑通过，再提交。
- `RuntimeRecoveryService` 不再直接持有跨上下文 `RecoverySnapshot` model 实例作为 UI 状态；主线程只发布值类型 DTO，后台协调器独占持久化扫描与更新。
- 冷启动允许做一次“未结项集合”级别的 bootstrap reconcile，但禁止再次对全部 `Message` 和全部 `RecoverySnapshot` 做无条件全量 fetch。
- 实时链路优先走增量事件，bootstrap 只补齐“应用重启后未收到 live event”的缺口。
- 所有后台 fetch 都必须通过新建的后台 `ModelContext` 完成，不能把 UI `modelContext` 跨 actor 传递。
- 批处理与节流要显式建模；不要在 `ChatView`、`agentGuiApp` 或 `ReliabilityCenterViewModel` 里散落 `Task.sleep` 和临时 debounce。
- 性能验收必须同时包含：算法级 focused tests，以及可重复的 baseline/smoke 采样命令。

## 2. Current State Summary

当前仓库里与 Feature 5 直接相关的现状如下：

1. `RuntimeRecoveryService.refresh(from:)` 仍在 `@MainActor` 上同步执行，并且会 `fetch(FetchDescriptor<Message>())`、`fetch(FetchDescriptor<RecoverySnapshot>())` 再做 upsert/delete/sort。
2. `ChatView.bootstrapSessionViewState()` 会在聊天页进入时并发调用 `refreshRecoverySummary()`，但它内部仍是 `try? runtimeRecoveryService.refresh(from: modelContext)`，因此恢复摘要和首屏消息渲染共享主线程预算。
3. `agentGuiApp` 启动时也会执行一次 `try? runtimeRecoveryService.refresh(from: context)`，因此应用冷启动与聊天页 bootstrap 都会触发同一条同步扫描路径。
4. Feature 4 已让 `RuntimeRecoveryService` 能从 `SessionRuntimeSnapshotStore` 派生 live runtime recovery item，但 persisted recovery 部分仍独立扫描 `Message` / `RecoverySnapshot`，真值和性能模型都没有收敛。
5. `ReliabilityCenterViewModel` 和 `ChatView` 目前都直接消费 `RecoverySnapshot` model，这会让后台上下文生成的新结果难以安全地跨隔离边界发布。

## 3. Desired End State

完成后应满足以下条件：

1. 聊天页和应用启动只会“请求恢复刷新”，不会在主线程同步等待 `Message` / `RecoverySnapshot` 全量扫描完成。
2. 持久化恢复项的刷新逻辑由单独的后台协调器串行处理，协调器内部维护“仍未结项 source key 集合”和“待处理事件批次”。
3. bootstrap reconcile 只查询两类集合：
   - 当前仍处于未完成状态的 source（例如 `status == .pending` 的 agent message、`status == .triggered/.running` 的 background task run）。
   - 当前已存在且仍可见的 recovery snapshot，用于检查哪些 source 已结束并需要删除。
4. 实时链路通过显式 source event 推动增量刷新：
   - `ExecutionPersistenceStore` 在 enqueue / finish / recoverableJobs 等路径上发送 message recovery source 更新。
   - `BackgroundTaskObservationService` 在 triggered / started / completed / failed / deferred / skipped 等路径上发送 background-task recovery source 更新。
5. `RuntimeRecoveryService` 向 UI 暴露值类型 persisted recovery item，例如 `PersistedRecoveryItem`，并提供基于 item ID 或 source key 的异步操作 API，而不是把 `RecoverySnapshot` model 直接交给视图。
6. 仓库中有 focused tests 证明刷新复杂度与“未结项 source 数量”相关，并有独立 smoke/baseline 命令可采样大样本场景。

## 4. File Plan

### New files

- `agentGui/Services/Recovery/RuntimeRecoveryRefreshCoordinator.swift`
- `agentGui/Services/Recovery/RuntimeRecoveryRefreshEvent.swift`
- `agentGui/Services/Recovery/PersistedRecoveryItem.swift`
- `agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests.swift`
- `agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift`
- `scripts/sample_runtime_recovery_refresh_baseline.sh`

### Existing files to modify

- `agentGui/Services/RuntimeRecoveryService.swift`
- `agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- `agentGui/Services/Background/BackgroundTaskObservationService.swift`
- `agentGui/Views/ChatView.swift`
- `agentGui/Views/Reliability/RecoveryBannerView.swift`
- `agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- `agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `agentGui/agentGuiApp.swift`
- `agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift`
- `agentGuiTests/TestSupport/InMemoryAppHarness.swift`

### Files that should stay unchanged in this feature

- `agentGui/ViewModels/ChatMessageListSnapshotBuilder.swift`
- `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- `agentGui/Services/Execution/ConversationExecutionRuntimeCoordinator.swift`

Feature 5 不要把这些文件一起重构，否则范围会越过需求边界。

## 5. Task 1: 先锁定异步增量 contract 与复杂度回归面

**Files:**
- Create: `agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests.swift`
- Modify: `agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift`

**Step 1: Write the failing test**

新增两组 focused tests：

1. `RuntimeRecoveryRefreshCoordinatorTests`
   - `bootstrapRefreshOnlyFetchesPendingSourcesAndVisibleSnapshots`
   - `incrementalMessageEventOnlyReconcilesAffectedMessageIDs`
   - `multipleQueuedEventsAreMergedIntoSingleBatch`
2. 扩充 `RuntimeRecoveryServiceRuntimeSnapshotTests`
   - 保证 live runtime summary 仍然完全来自 `SessionRuntimeSnapshotStore`，不被 persisted refresh 改动破坏。

建议测试骨架：

```swift
@Test
func incrementalMessageEventOnlyReconcilesAffectedMessageIDs() async throws {
    let repository = RecoveryRefreshRepositorySpy()
    let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository, clock: TestClock())

    await coordinator.enqueue(.messageChanged(messageIDs: [UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!]))
    let snapshot = try await coordinator.flushForTesting()

    #expect(repository.messageFetchCalls == [.specificIDs(1)])
    #expect(snapshot.updatedItemIDs.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task1 -only-testing:agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the coordinator, event DTOs, and merge/batch contract do not exist yet.

**Step 3: Write minimal implementation**

先只建立 contract，不接 UI：

- 新增 `RuntimeRecoveryRefreshEvent`，至少覆盖 `.bootstrap`, `.messageChanged`, `.backgroundTaskChanged`, `.snapshotActionCompleted`。
- 新增 `RuntimeRecoveryRefreshCoordinator` actor 的最小接口。
- 提供测试专用 `flushForTesting()` 或等价同步钩子，避免测试依赖真实 sleep/debounce。

建议接口：

```swift
actor RuntimeRecoveryRefreshCoordinator {
    func enqueue(_ event: RuntimeRecoveryRefreshEvent) async
    func flushForTesting() async throws -> RuntimeRecoveryRefreshResult
}
```

此步不要碰 `RuntimeRecoveryService` 的现有 API，只让测试先能表达 contract。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS for contract-level tests.

**Step 5: Commit**

```bash
git add agentGui/Services/Recovery/RuntimeRecoveryRefreshCoordinator.swift agentGui/Services/Recovery/RuntimeRecoveryRefreshEvent.swift agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests.swift agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift
git commit -m "test: lock runtime recovery incremental refresh contract"
```

## 6. Task 2: 建立后台 SwiftData 协调器和值类型 persisted recovery presentation

**Files:**
- Create: `agentGui/Services/Recovery/PersistedRecoveryItem.swift`
- Modify: `agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/Reliability/RecoveryBannerView.swift`
- Modify: `agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- Modify: `agentGui/Views/Reliability/ReliabilityCenterView.swift`
- Modify: `agentGui/agentGuiApp.swift`

**Step 1: Write the failing test**

新增或补充测试覆盖：

1. `RuntimeRecoveryServiceIncrementalTests.persistedRecoveryItemsPublishWithoutExposingModelInstances`
2. `RuntimeRecoveryServiceIncrementalTests.bootstrapRefreshReturnsImmediatelyAndPublishesLater`
3. `ReliabilityCenterViewModel` 或视图层的最小测试，确认它们消费的是 `PersistedRecoveryItem` 而不是 `RecoverySnapshot`。

建议测试骨架：

```swift
@Test
func bootstrapRefreshReturnsImmediatelyAndPublishesLater() async throws {
    let harness = try InMemoryAppHarness.makeRecoveryScenario()
    let service = RuntimeRecoveryService()
    service.configurePersistence(container: harness.container)

    let started = ContinuousClock.now
    await service.scheduleBootstrapRefresh()
    let elapsed = started.duration(to: .now)

    #expect(elapsed < .milliseconds(50))
    await service.waitForRefreshForTesting()
    #expect(service.recoveryItems(for: harness.session.sessionId).isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task2 -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `RuntimeRecoveryService` still requires a foreground `ModelContext` and still publishes `RecoverySnapshot` models directly.

**Step 3: Write minimal implementation**

实现这条主干：

- `RuntimeRecoveryService` 新增 `configurePersistence(container:)` 或等价绑定方法，用于创建后台协调器。
- `RuntimeRecoveryService` 新增非阻塞 API，例如 `scheduleBootstrapRefresh()` / `scheduleRefresh(_:)`，主线程只投递请求，不等待后台扫描完成。
- 把 `activeSnapshots: [RecoverySnapshot]` 替换为 `persistedRecoveryItems: [PersistedRecoveryItem]`。
- `ChatView` 启动时把 `try? runtimeRecoveryService.refresh(from: modelContext)` 改成请求式刷新；`agentGuiApp` 冷启动同样改成请求式。
- `RecoveryBannerView` 增加 `PersistedRecoveryItem` 初始化入口；`ReliabilityCenterViewModel` 和 `ReliabilityCenterView` 不再直接 fetch `RecoverySnapshot` 当作展示态。

建议值类型：

```swift
struct PersistedRecoveryItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let sessionID: String
    let sourceKind: RecoverySourceKind
    let sourceIdentifier: String
    let titleText: String
    let summaryText: String
    let handlingState: RecoveryHandlingState
}
```

注意：

- `markViewed` / `markInterrupted` / `clear` 改成接受 `PersistedRecoveryItem` 或 `itemID`，并在后台上下文完成 targeted mutation。
- 不要让视图层继续持有来自后台 `ModelContext` 的 live model。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command, then再补一个 UI/VM focused command：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task2b -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Recovery/PersistedRecoveryItem.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/Views/ChatView.swift agentGui/Views/Reliability/RecoveryBannerView.swift agentGui/ViewModels/ReliabilityCenterViewModel.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGui/agentGuiApp.swift agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests.swift agentGuiTests/TestSupport/InMemoryAppHarness.swift
git commit -m "refactor: move persisted recovery presentation off main-thread models"
```

## 7. Task 3: 接入 message 和 background task 的增量恢复源

**Files:**
- Modify: `agentGui/Services/Execution/ExecutionPersistenceStore.swift`
- Modify: `agentGui/Services/Background/BackgroundTaskObservationService.swift`
- Modify: `agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `agentGui/agentGuiApp.swift`
- Modify: `agentGuiTests/TestSupport/InMemoryAppHarness.swift`
- Modify: `agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift`

**Step 1: Write the failing test**

补 live source tests：

1. `enqueueCreatesTargetedMessageRecoveryRefreshEvent`
2. `finishRemovesResolvedMessageRecoveryWithoutFullBootstrap`
3. `backgroundRunLifecycleSendsTargetedRefreshEvents`
4. `multipleLiveEventsCoalesceBeforeBackgroundRefreshExecutes`

建议测试骨架：

```swift
@Test
func finishRemovesResolvedMessageRecoveryWithoutFullBootstrap() async throws {
    let sink = RuntimeRecoveryRefreshSinkSpy()
    let store = ExecutionPersistenceStore(
        modelContext: context,
        persistenceCoordinator: .shared,
        recoveryRefreshSink: sink
    )

    try store.finish(jobID: jobID, attemptID: attemptID, outcome: .completed)

    #expect(sink.events.contains(.messageChanged(messageIDs: [agentMessageID])))
    #expect(sink.bootstrapRequests == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task3 -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because neither persistence store nor background observation service emits recovery refresh events.

**Step 3: Write minimal implementation**

落地增量源接线：

- 为 `ExecutionPersistenceStore` 新增可选 `recoveryRefreshSink` 依赖。
- 在这些路径发出 targeted event：
  - `enqueue(...)`：agent pending message 新建后发 `.messageChanged([agentMessageID])`
  - `finish(...)`：对应 agent message 收敛后再次发 `.messageChanged([targetAgentMessageID])`
  - `recoverableJobs()`：恢复 running -> queued 时，对受影响 message 重新发 targeted event
- 为 `BackgroundTaskObservationService` 新增同样的 sink，在 `recordTriggeredRun` / `recordStarted` / `recordCompleted` / `recordFailed` / `recordDeferred` / `recordSkipped` 后发 `.backgroundTaskChanged([run.id])`
- `agentGuiApp` 创建单例 `BackgroundTaskObservationService` 时，把 `RuntimeRecoveryService` 的 sink 传进去，不要继续散落创建多个无 sink 的 observation service。

建议依赖形式：

```swift
protocol RuntimeRecoveryRefreshSink: Sendable {
    func enqueue(_ event: RuntimeRecoveryRefreshEvent) async
}
```

这里不要把 `RuntimeRecoveryService` 直接塞进 `ExecutionPersistenceStore`；用 protocol/closure 保持依赖单向。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command, then再跑恢复链路 focused suite：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task3b -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Execution/ExecutionPersistenceStore.swift agentGui/Services/Background/BackgroundTaskObservationService.swift agentGui/Services/RuntimeRecoveryService.swift agentGui/agentGuiApp.swift agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift agentGuiTests/TestSupport/InMemoryAppHarness.swift
git commit -m "feat: feed runtime recovery refresh from incremental message and task events"
```

## 8. Task 4: 实现 bootstrap reconcile、节流和批量保存策略

**Files:**
- Modify: `agentGui/Services/Recovery/RuntimeRecoveryRefreshCoordinator.swift`
- Modify: `agentGui/Services/RuntimeRecoveryService.swift`
- Modify: `agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests.swift`
- Modify: `agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift`

**Step 1: Write the failing test**

补这四类行为测试：

1. `bootstrapReconcileRemovesVisibleSnapshotsWhoseSourcesAlreadyFinished`
2. `bootstrapReconcileDoesNotFetchAllMessagesWhenOnlyThreePendingRemain`
3. `burstOfFiftyEventsProducesBoundedNumberOfSaveOperations`
4. `userActionsTriggerTargetedMutationAndFollowupRefresh`

建议测试骨架：

```swift
@Test
func burstOfFiftyEventsProducesBoundedNumberOfSaveOperations() async throws {
    let repository = RecoveryRefreshRepositorySpy()
    let coordinator = RuntimeRecoveryRefreshCoordinator(
        repository: repository,
        batchPolicy: .init(maxEventsPerBatch: 20, debounce: .milliseconds(100)),
        clock: TestClock()
    )

    for index in 0..<50 {
        await coordinator.enqueue(.messageChanged(messageIDs: [UUID(index)]))
    }

    try await coordinator.drainForTesting()
    #expect(repository.saveCallCount <= 3)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task4 -only-testing:agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the initial coordinator only defined contract and does not yet perform real reconcile, batching, or targeted delete logic.

**Step 3: Write minimal implementation**

在协调器里补齐真正的算法：

- 维护 `trackedVisibleSources`，来源于上一次成功刷新后仍可见的 persisted recovery items。
- bootstrap 时只查询：
  - 未完成 agent message 集合
  - 未完成 background task run 集合
  - 当前仍可见 recovery snapshot 集合
- 根据 `trackedVisibleSources + 本批 dirty IDs` 计算最小 reconcile 范围；不允许 fallback 到“把所有 message 再 fetch 一遍”。
- 批量 upsert / delete 完成后一次保存，再产出新的 `PersistedRecoveryItem` 列表供主线程发布。
- 对 `markViewed` / `markInterrupted` / `clear` 使用 targeted mutation，再追加 `.snapshotActionCompleted` 事件让展示态收敛。

建议内部结果：

```swift
struct RuntimeRecoveryRefreshResult: Sendable {
    let items: [PersistedRecoveryItem]
    let updatedItemIDs: Set<UUID>
    let removedSourceKeys: Set<String>
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Recovery/RuntimeRecoveryRefreshCoordinator.swift agentGui/Services/RuntimeRecoveryService.swift agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests.swift agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift
git commit -m "feat: add batched bootstrap reconcile for persisted recovery refresh"
```

## 9. Task 5: 增加基线采样脚本和最终 focused validation

**Files:**
- Create: `scripts/sample_runtime_recovery_refresh_baseline.sh`
- Modify: `agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift`
- Modify: `docs/quality/` output paths only when generating samples;不要把采样结果文件纳入这份实现本身

**Step 1: Write the failing test**

为 focused tests 再补一条带大样本 fixture 的 smoke case，例如：

- `largeHistoryWithSmallPendingSetRefreshesAgainstPendingCardinality`

测试目标不是硬编码绝对耗时，而是验证 repository spy 只读取 pending subset 和 tracked visible snapshots。

建议骨架：

```swift
@Test
func largeHistoryWithSmallPendingSetRefreshesAgainstPendingCardinality() async throws {
    let repository = RecoveryRefreshRepositorySpy(historyMessageCount: 10_000, pendingMessageCount: 3)
    let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository, clock: TestClock())

    _ = try await coordinator.performBootstrapRefreshForTesting()

    #expect(repository.fetchedMessageCount == 3)
    #expect(repository.fullMessageScanCount == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-plan-task5 -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until the repository/coordinator exposes the right counters or spy seams.

**Step 3: Write minimal implementation**

新增 baseline/smoke 入口：

- 参考 `scripts/sample_quality_baseline.sh`，增加 `scripts/sample_runtime_recovery_refresh_baseline.sh`。
- 脚本运行 focused test 子集并把 wall time / observed xcodebuild elapsed 写入 `docs/quality/samples/runtime-recovery-refresh-baseline-<timestamp>.md`。
- 如果需要，脚本支持参数：样本次数、pending 数量、history 数量、输出路径。

建议命令核心：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-baseline -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests CODE_SIGNING_ALLOWED=NO
```

注意：

- 不要在单测里断言“必须小于 N ms”这种脆弱指标。
- 单测负责证明算法复杂度；脚本负责采样真实运行时间。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command, then采样一次脚本：

```bash
./scripts/sample_runtime_recovery_refresh_baseline.sh 3 docs/quality/samples/runtime-recovery-refresh-baseline-manual.md
```

Expected: PASS, and baseline markdown is generated.

**Step 5: Commit**

```bash
git add scripts/sample_runtime_recovery_refresh_baseline.sh agentGuiTests/RuntimeRecoveryServiceIncrementalTests.swift
git commit -m "test: add runtime recovery refresh smoke baseline"
```

## 10. Final Validation Checklist

全部任务完成后，按顺序验证：

1. `xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-runtime-recovery-final -only-testing:agentGuiTests/RuntimeRecoveryRefreshCoordinatorTests -only-testing:agentGuiTests/RuntimeRecoveryServiceIncrementalTests -only-testing:agentGuiTests/RuntimeRecoveryServiceRuntimeSnapshotTests -only-testing:agentGuiTests/ConversationExecutionRecoveryTests CODE_SIGNING_ALLOWED=NO`
2. 手动打开聊天页，确认首屏消息先出现，恢复 banner 在后台刷新完成后再出现或收敛；不能因为恢复刷新卡住消息列表。
3. 搜索 `RuntimeRecoveryService.swift`，确认不存在 `func refresh(from modelContext: ModelContext) throws` 这种要求调用方传 UI `ModelContext` 的主线程全量扫描入口；若保留同名 API，它必须只是调度后台刷新请求的兼容壳。
4. 搜索 `ChatView.swift` 和 `agentGuiApp.swift`，确认它们调用的是 `scheduleBootstrapRefresh` / `scheduleRefresh` 之类非阻塞 API，而不是 `try? refresh(from:)`。
5. 搜索 `RecoveryBannerView.swift`、`ReliabilityCenterView.swift`、`ReliabilityCenterViewModel.swift`，确认 persisted recovery UI 只消费 `PersistedRecoveryItem`，不再持有 `RecoverySnapshot` live model。
6. 搜索 `ExecutionPersistenceStore.swift` 和 `BackgroundTaskObservationService.swift`，确认 live source event 已接上 recovery refresh sink，且没有把 `RuntimeRecoveryService` 直接硬编码进低层持久化类。
7. 运行一次 `./scripts/sample_runtime_recovery_refresh_baseline.sh 5`，确认生成采样文件，且输出可用于和后续优化迭代对比。

## 11. Risks and Guardrails

- 风险 1：如果后台协调器仍然在每批刷新里 `fetch(FetchDescriptor<Message>())`，那么线程换了但复杂度没变。规避方式：只允许 pending subset fetch 和 tracked visible snapshot fetch，测试里显式断言这一点。
- 风险 2：如果继续把 `RecoverySnapshot` live model 暴露给视图，后台上下文与主线程上下文会混淆，容易引入崩溃或陈旧状态。规避方式：统一改成值类型 DTO。
- 风险 3：如果 `ExecutionPersistenceStore` 和 `BackgroundTaskObservationService` 不发 targeted event，系统会退回“每次都 bootstrap reconcile”的伪增量。规避方式：把 live source event 当成功能验收的一部分，而不是可选优化。
- 风险 4：如果把节流逻辑写在视图层，后续会话切换和 diagnostics 刷新会再次出现多头 debounce。规避方式：所有 merge/batch policy 只放在 `RuntimeRecoveryRefreshCoordinator`。
- 风险 5：如果在本轮顺手改 `ChatMessageListSnapshotBuilder` 或 ACP session actor，容易把性能收益和回归风险混在一起，无法判断 Feature 5 是否独立成立。规避方式：严格限制文件范围。

## 12. Handoff Notes

- 先替换 persisted recovery 的数据流，再优化 live source；不要反过来，否则 UI 还在直接消费 `RecoverySnapshot` model，后台 actor 接不进去。
- 任务执行时优先保持旧 UI 文案和交互不变，避免产品行为变化掩盖性能重构本身的回归。
- 如果实现过程中发现 `RecoverySnapshot` 需要额外索引字段才能高效按 `sourceKind + sourceIdentifier` 查询，允许在本 feature 内增补模型字段或 fetch helper，但不要升级为新的通用 event journal。
- Feature 5 完成后，下一份相关计划应接 Feature 6，继续把消息列表 snapshot build 从主线程搬离；不要在本 feature 内顺手实现。