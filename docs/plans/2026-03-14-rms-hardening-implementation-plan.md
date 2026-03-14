# RMS Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复 RMS 当前最关键的 6 个落地问题，让 epistemic extraction、RMS retrieval、预算治理、后台 job、状态观测和 UI 绑定都真正进入主链路。

**Architecture:** 采用原位修复，不新增第二套 RMS 运行时。优先修正主链路接线和 feature gate 语义，再补最终预算闸门、job 生命周期治理和观测入口，最后用当前 task 绑定的 runtime snapshot 驱动 UI。整个方案保持现有 `ClaudeService -> AgentLoop hooks -> MemoryRuntimeCoordinator -> Snapshot/UI` 框架，只删除假开关、弱约束和错误入口，不扩展新存储后端。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, SwiftAnthropic, `xcodebuild`, `./scripts/run_quality_smoke.sh`.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 本计划只覆盖你刚才 review 里确认的 6 个问题，不顺手改 unrelated memory features。
- 执行顺序按依赖关系排布：先修接线和 feature gate，再修预算和后台调度，最后修观测和 UI。
- 除特别说明外，每个任务都先写失败测试，再做最小实现，再跑定向测试，最后提交。

## Task 1: Replace Fallback-Only Epistemic Bootstrap With Real Coordinator Wiring

**Files:**
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Models/AppSettings.swift`
- Test: `agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- Test: `agentGuiTests/EpistemicStateCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing test**

新增测试锁定主链路行为：`enableEpistemicExtraction = true` 时，bootstrap 不能再无条件走 `.fallbackOnly()`，而应使用真实 `EpistemicStateCoordinator(service:modelId:)`；关闭时才允许 fallback。

```swift
@Test func memoryBootstrapUsesRealEpistemicCoordinatorWhenExtractionEnabled() async throws {
    let settings = AppSettings.testFixture()
    settings.enableUnifiedMemoryRuntime = true
    settings.enableEpistemicExtraction = true

    let factory = makeHookFactory(settings: settings)
    let state = AgentLoopBuiltInHookFactory.State()

    _ = try await factory.build(state: state).memoryBootstrapLoader(state)

    #expect(state.epistemicState.frontiers.isEmpty == false)
    #expect(state.influenceTrace.frontierBudgetDecisions.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because `loadEpistemicBootstrapState` still hardcodes `.fallbackOnly()`.

**Step 3: Write minimal implementation**

把 `loadEpistemicBootstrapState` 改成显式 gate：

1. 读取 `runtime.settings.enableEpistemicExtraction`
2. 开启时使用当前 `request.service` 和 `request.modelId` 构造真实 `EpistemicStateCoordinator`
3. 关闭时保留 `.fallbackOnly()`
4. 如果真实 extraction 失败，再明确记录 fallback 原因，而不是静默退化

核心形态应接近：

```swift
let coordinator: EpistemicStateCoordinator
if runtime.settings.enableEpistemicExtraction {
    coordinator = EpistemicStateCoordinator(service: request.service, modelId: request.modelId)
} else {
    coordinator = .fallbackOnly()
}
let buildResult = try await coordinator.buildState(from: envelopes)
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHookDependencyFactory.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Models/AppSettings.swift agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift agentGuiTests/EpistemicStateCoordinatorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "fix: wire real epistemic bootstrap coordinator"
```

## Task 2: Expand EpistemicStateCoordinator Into A Full Multi-Stage Extraction Pipeline

**Files:**
- Modify: `agentGui/Services/EpistemicStateCoordinator.swift`
- Modify: `agentGui/Services/EpistemicExtractionService.swift`
- Modify: `agentGui/Services/EpistemicStateReducer.swift`
- Test: `agentGuiTests/EpistemicStateCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing test**

锁定 `EpistemicExtractionService` 提供的四类能力都要进入主流程，而不是只跑 `extractEvents`。

```swift
@Test func coordinatorRunsEventFrontierCounterexampleAndConstraintStages() async throws {
    let service = EpistemicExtractionService { prompt in
        if prompt.contains("AtomicEpistemicEvent") { return eventsJSON }
        if prompt.contains("frontiers") { return frontierJSON }
        if prompt.contains("counterexamples") { return counterexampleJSON }
        return constraintDebtJSON
    }

    let result = try await EpistemicStateCoordinator(extractionService: service)
        .buildState(from: [.fixture()])

    #expect(result.state.frontiers.isEmpty == false)
    #expect(result.state.counterexamples.isEmpty == false)
    #expect(result.state.activeConstraints.isEmpty == false)
    #expect(result.state.verificationDebt.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests
```

Expected: FAIL because `buildState` currently only calls `extractEvents`.

**Step 3: Write minimal implementation**

把 `buildState` 拆成明确阶段：

1. `extractEvents(from:state:)`
2. 从 event output 中收集 `AtomicEpistemicEvent`
3. `synthesizeFrontiers(from:state:)`
4. `extractCounterexamples(from:state:)`
5. `extractConstraintsAndDebt(from:state:)`
6. 按固定顺序 reduce 到单一 `EpistemicState`

若任一阶段失败：

1. 保留已成功阶段结果
2. 仅对失败阶段应用 scoped fallback
3. 不再让整轮退化成一个笼统 frontier

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/EpistemicStateCoordinator.swift agentGui/Services/EpistemicExtractionService.swift agentGui/Services/EpistemicStateReducer.swift agentGuiTests/EpistemicStateCoordinatorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "feat: run full epistemic extraction pipeline"
```

## Task 3: Make RMS Feature Flags Control Real Runtime Behavior

**Files:**
- Modify: `agentGui/Models/MemoryRuntimeTypes.swift`
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Views/Settings/SettingsMemoryView.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Test: `agentGuiTests/MemoryRuntimeSettingsTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing test**

新增集成测试，确保三个开关都能改变真实行为，而不是只影响 UI。

```swift
@Test func runtimeSkipsDistillationJobsWhenRMSDistillationDisabled() async throws {
    let coordinator = MemoryRuntimeCoordinator(
        featureConfiguration: .init(
            enableEpistemicExtraction: true,
            enableRMSRetrieval: true,
            enableRMSDistillation: false
        ),
        unifiedRecordsProvider: { _ in [] },
        unifiedStoreBaseDirectory: try makeTemporaryDirectory()
    )

    await coordinator.scheduleConsolidation(for: makeOutcome())

    let jobs = try MemoryBackgroundJobStore(baseDirectory: coordinatorBaseDirectory).allJobs()
    #expect(jobs.contains { $0.type == .consolidation })
    #expect(jobs.contains { $0.type == .counterexampleDistillation } == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because `scheduleConsolidation` still unconditionally enqueues all jobs.

**Step 3: Write minimal implementation**

把 feature flag 变成 runtime gate：

1. `enableEpistemicExtraction` 决定是否构建真实 epistemic state
2. `enableRMSRetrieval` 决定是否进入 frontier-aware retrieval intent / influence trace 增强
3. `enableRMSDistillation` 决定是否 enqueue counterexample/tactic/invalidation jobs
4. Settings footer 文案补充“当前哪些开关已真正生效”说明

预期逻辑：

```swift
if featureConfiguration.enableRMSDistillation {
    try backgroundJobStore.enqueue(.counterexampleDistillation(outcome: outcome))
    try backgroundJobStore.enqueue(.tacticKernelDistillation(outcome: outcome))
    try backgroundJobStore.enqueue(.memoryInvalidation(outcome: outcome))
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryRuntimeTypes.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGuiTests/MemoryRuntimeSettingsTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "fix: make rms feature flags gate runtime behavior"
```

## Task 4: Add Final Prompt Budget Enforcement Instead Of Record-Count Approximation

**Files:**
- Create: `agentGui/Services/MemoryPromptBudgetEnforcer.swift`
- Modify: `agentGui/Services/MemoryPromptAssembler.swift`
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `agentGui/Models/MemoryRuntimeSnapshot.swift`
- Test: `agentGuiTests/MemoryPromptBudgetingTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryPromptAssemblerTests.swift`

**Step 1: Write the failing test**

锁定最终注入 prompt 必须被硬限制在预算内，并记录裁剪信息。

```swift
@Test func renderedPromptIsTrimmedToContextBudgetAndRecordsTrimMetadata() async throws {
    let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: longFixtureRecords())
    let request = MemoryRuntimeRequest(
        sessionId: "s1",
        threadId: "t1",
        workflowRunId: nil,
        userRequest: "Fix build",
        taskKind: .coding,
        projectId: nil,
        workspaceRoot: "/tmp/repo",
        contextBudget: 2000
    )

    let context = try await coordinator.prepareContext(for: request)
    let snapshot = try #require(context.runtimeSnapshot)

    #expect(context.renderedPrompt.count <= 2000)
    #expect(snapshot.metrics.totalEstimatedPromptChars >= context.renderedPrompt.count)
    #expect(snapshot.metrics.trimmedCharCount > 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryPromptBudgetingTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryPromptAssemblerTests
```

Expected: FAIL because current pipeline only budgets record counts, not final prompt length.

**Step 3: Write minimal implementation**

新增最终预算闸门：

1. `MemoryPromptAssembler` 先生成分 section 的中间表示
2. `MemoryPromptBudgetEnforcer` 基于 `contextBudget` 做最终截断
3. 优先保留顺序固定：frontiers > counterexamples > constraints > verification debt > verified facts > speculative warnings > episodic records
4. snapshot metrics 新增：`trimmedCharCount`、`postEnforcementPromptChars`、`trimmedSectionIDs`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryPromptBudgetEnforcer.swift agentGui/Services/MemoryPromptAssembler.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/MemoryRuntimeSnapshot.swift agentGuiTests/MemoryPromptBudgetingTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryPromptAssemblerTests.swift
git commit -m "feat: enforce final unified-memory prompt budget"
```

## Task 5: Harden Background Job Scheduling, TTL Sweep, And Failure Recovery

**Files:**
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `agentGui/Services/MemoryBackgroundJobStore.swift`
- Modify: `agentGui/Models/MemoryBackgroundJob.swift`
- Modify: `agentGui/agentGuiApp.swift`
- Modify: `agentGui/Services/MemoryGovernanceService.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryRetentionServiceTests.swift`

**Step 1: Write the failing test**

至少补两类失败测试：TTL 会按周期继续运行；失败 job 会进入 retry/backoff，而不是永久停在 failed。

```swift
@Test func schedulerRequeuesPeriodicTTLSweepAfterInterval() async throws {
    let baseDirectory = try makeTemporaryDirectory()
    let scheduler = MemoryBackgroundScheduler(baseDirectory: baseDirectory)
    let jobStore = MemoryBackgroundJobStore(baseDirectory: baseDirectory)

    await scheduler.runOnce(now: Date(timeIntervalSince1970: 10_000))
    await scheduler.runOnce(now: Date(timeIntervalSince1970: 10_400))

    #expect(try jobStore.latestSweepReport() != nil)
    #expect(try jobStore.allJobs().contains { $0.type == .ttlSweep })
}
```

```swift
@Test func failedBackgroundJobMovesToRetryableStateBeforeDeadLetter() async throws {
    let store = MemoryBackgroundJobStore(baseDirectory: try makeTemporaryDirectory())
    try store.enqueue(.fixtureFailingConsolidationJob())

    await makeAlwaysFailingScheduler(store: store).runOnce()

    let job = try #require(store.allJobs().first)
    #expect(job.attemptCount == 1)
    #expect(job.status == .queued || job.status == .failed)
    #expect(job.failureSummary?.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/MemoryRetentionServiceTests
```

Expected: FAIL because TTL is only enqueued at app launch and failed jobs have no retry semantics.

**Step 3: Write minimal implementation**

实现 job 生命周期治理：

1. `MemoryBackgroundJob` 增加 `nextEligibleRunAt`、`maxAttempts`、`lastFailureAt`
2. `MemoryBackgroundJobStore.nextQueuedJob()` 改为挑选“已到运行时间”的 queued job
3. `MemoryBackgroundScheduler` 在内部判断是否需要自投 TTL sweep job
4. 普通失败按指数退避重排回 queued；超过上限后标记 failed/dead-letter
5. `agentGuiApp` 不再在启动时手工塞一次 ttlSweep job

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Services/MemoryBackgroundJobStore.swift agentGui/Models/MemoryBackgroundJob.swift agentGui/agentGuiApp.swift agentGui/Services/MemoryGovernanceService.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryRetentionServiceTests.swift
git commit -m "fix: harden rms background job lifecycle"
```

## Task 6: Make RMS Observability Follow The Current Task Instead Of Global Latest Snapshot

**Files:**
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `agentGui/Services/MemoryRuntimeSnapshotStore.swift`
- Modify: `agentGui/Views/Memory/RMSCognitionPanel.swift`
- Modify: `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Modify: `agentGui/Views/ToolCallDetailContentView.swift`
- Test: `agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift`
- Test: `agentGuiTests/ToolCallDetailPresentationTests.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing test**

锁定 UI 必须优先展示当前 tool call / 当前任务绑定的 snapshot，而不是最近一次 session snapshot。

```swift
@Test func cognitionPanelPrefersBoundSnapshotOverGlobalLatest() throws {
    let store = MemoryRuntimeSnapshotStore(baseDirectory: try makeTemporaryDirectory())
    try store.save(.fixture(id: "older-current", sessionId: "s1", toolCallId: "tool-1", createdAt: .init(timeIntervalSince1970: 100)))
    try store.save(.fixture(id: "newer-other", sessionId: "s2", toolCallId: "tool-2", createdAt: .init(timeIntervalSince1970: 200)))

    let snapshot = try #require(store.snapshot(id: "older-current"))
    #expect(snapshot.id == "older-current")
}
```

以及观测 sink 测试：

```swift
@Test func unifiedMemoryRuntimeEmitsBusinessLogsOnProductionPath() async throws {
    let sink = InMemoryBusinessLogSink()
    let service = ClaudeService()
    service.businessLogSink = sink

    _ = try await service.buildUnifiedMemoryBootstrap(...)

    #expect(sink.events.contains { $0.event == .memoryContextPrepared })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeSnapshotStoreTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because production runtime paths do not pass `businessLogSink`, and RMS panel still reads global latest snapshot.

**Step 3: Write minimal implementation**

完成三处修正：

1. `ClaudeService.buildUnifiedMemoryBootstrap` 构造 `MemoryRuntimeCoordinator` 时传入 `businessLogSink`
2. `agentGuiApp` 构造 `MemoryBackgroundScheduler` 时传入 `claudeService.businessLogSink`
3. `RMSCognitionPanel` 新增基于 `snapshotID` 或 `toolCall.memoryRuntimeSnapshotID` 的加载入口；只有在没有绑定快照时才回落到 `latestSnapshotInMostRecentSession()`

同时在 view model 里补可视诊断字段：

1. `wasFallbackExtractionUsed`
2. `postEnforcementPromptChars`
3. `trimmedCharCount`
4. `jobBacklogCount` 或最近失败 job 摘要

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Run smoke validation**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Services/MemoryRuntimeSnapshotStore.swift agentGui/Views/Memory/RMSCognitionPanel.swift agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift agentGuiTests/ToolCallDetailPresentationTests.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "fix: bind rms observability to current task snapshot"
```

## Recommended Execution Order

1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5
6. Task 6

理由：Task 1-3 决定主链路是否真实工作；Task 4 依赖真实 retrieval data；Task 5 稳定后台生命周期；Task 6 最后收口观测和 UI，避免先做 UI 再返工数据契约。

## Exit Criteria

全部任务完成后，必须额外确认：

1. `enableEpistemicExtraction`、`enableRMSRetrieval`、`enableRMSDistillation` 都存在可证明的行为差异
2. `EpistemicExtractionService` 的四类能力都有真实调用点
3. `renderedPrompt.count <= contextBudget` 在定向测试中被锁定
4. TTL sweep 不依赖 app 启动时的一次性 enqueue
5. failed job 不会永久无人处理
6. RMS 面板能打开当前 task 绑定快照，而不是全局最新快照
7. `Quality Smoke` 通过

Plan complete and saved to `docs/plans/2026-03-14-rms-hardening-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按任务逐个实现、每个任务之间复查并回报

**2. Parallel Session (separate)** - 你开新会话，按这份 plan 用 executing-plans 模式批量执行

**Which approach?**