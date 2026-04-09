# RMS Agent-First Replacement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用一套极简、单主链、agent-first 的 RMS 替换当前 record-centric memory control plane，在保留 frontier / constraint / counterexample / verification debt / prompt injection 能力的前提下，删除旧 coordinator、planner、governance、background jobs、legacy UI 和 rollout flags。

**Architecture:** 不做兼容层，不保留双轨运行时。新实现只保留 `RMSState`、`RMSInsight`、`RMSExtractor`、`RMSReducer`、`RMSSelector`、`RMSPromptComposer` 六个核心对象/组件。先建立新模型和新 prompt 主链，再把 agent loop、UI、settings 切到新实现，最后批量删除旧 RMS 运行时与对应测试，确保代码库最终只剩一套 memory 语义。

**Tech Stack:** Swift 6、SwiftData、SwiftUI、Swift Testing、SwiftAnthropic、现有 AgentLoop runtime、`xcodebuild`、`./scripts/run_quality_smoke.sh`。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 1. Design constraints

- 不允许保留旧 `MemoryRuntimeCoordinator` 作为适配层。
- 不允许保留 layer/profile/governance/TTL/distillation 的兼容分支。
- 不允许让 UI 再回退到“最近 session 的 latest snapshot”。
- 新 RMS 必须直接绑定当前 task / thread 的状态。
- 长期存储只能保留 `constraint`、`counterexample`、`tactic` 三类 insight。
- 实施过程中允许短暂编译失败，但最终合入状态里不能同时存在两套 RMS 主链。

## 2. Target file set

### Create

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RMSState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RMSInsight.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RMSDelta.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSInsightStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSSelector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSPromptComposer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSSelectorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSPromptComposerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSPanelViewModelTests.swift`

### Modify

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsMemoryNavigationStateTests.swift`

### Delete

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConfirmationWorkflowService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConflictResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DefaultMemoryAdmissionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSCognitionPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalIntentClassifierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetentionServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryPromptAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementDashboardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConsolidationEngineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConflictResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryAdmissionPolicyTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSCognitionPanelViewModelTests.swift`

## 3. Task breakdown

### Task 1: Lock the new RMS domain with failing tests

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSStateTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSSelectorTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSPromptComposerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`

**Step 1: Write the failing tests**

先锁定新 RMS 的最小契约：

1. `RMSState` 能表达 frontiers、constraints、counterexamples、verification debts、candidate actions、stop signals。
2. `RMSSelector` 只按 decision change 选择 insight，而不是 layer/profile。
3. `RMSPromptComposer` 只能输出固定的 5 个 section。
4. `AgentLoopMemoryBootstrapComposer` 在新主链下直接使用 `RMSPromptComposer` 输出，而不是旧 `renderEpistemicSummary + unifiedContext.renderedPrompt` 拼接逻辑。

示例测试：

```swift
@Test func selectorPrefersConstraintThenCounterexampleThenTactic() {
    let state = RMSState(taskID: "t1", sessionID: "s1", threadID: "th1", summary: "Fix smoke failure")
    let insights = [
        RMSInsight.constraint(id: "c1", summary: "Run targeted test first", appliesWhen: "coding", changesDecision: "blocks editing before evidence"),
        RMSInsight.counterexample(id: "x1", summary: "Editing before reading snapshot caused regression", appliesWhen: "coding", changesDecision: "inspect first", replacementAction: "read current failure output"),
        RMSInsight.tactic(id: "k1", summary: "Use xcodebuild -only-testing", appliesWhen: "swift test triage", changesDecision: "narrow verification scope")
    ]

    let selected = RMSSelector().select(for: state, insights: insights, budget: 2)

    #expect(selected.map(\.id) == ["c1", "x1"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSStateTests \
  -only-testing:agentGuiTests/RMSSelectorTests \
  -only-testing:agentGuiTests/RMSPromptComposerTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests
```

Expected: FAIL because the new RMS types and composer do not exist.

**Step 3: Write minimal implementation**

Create:

1. `RMSState.swift`
2. `RMSInsight.swift`
3. `RMSDelta.swift`
4. `RMSSelector.swift`
5. `RMSPromptComposer.swift`

Keep the first pass small:

1. no persistence yet
2. no extraction yet
3. only pure models + selector + prompt rendering

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/RMSState.swift agentGui/Models/RMSInsight.swift agentGui/Models/RMSDelta.swift agentGui/Services/RMSSelector.swift agentGui/Services/RMSPromptComposer.swift agentGuiTests/RMSStateTests.swift agentGuiTests/RMSSelectorTests.swift agentGuiTests/RMSPromptComposerTests.swift agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift
git commit -m "feat: add rms core domain and prompt selection"
```

### Task 2: Replace bootstrap composition with the new RMS prompt path

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing integration tests**

Add tests that enforce:

1. bootstrap reads `RMSState` + selected insights
2. bootstrap injects one unified user/assistant pair
3. bootstrap no longer depends on `MemoryRuntimeContext.renderedPrompt`
4. no `runtimeSnapshotID`, `runtimeIntentPhase`, `runtimeWorkingSetCost`, `runtimeDereferenceCount` metadata is required for the happy path

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because the composer still depends on legacy memory runtime types.

**Step 3: Implement the new bootstrap path**

Make these changes:

1. change `AgentLoopMemoryBootstrapComposer.Dependencies` from `loadUnifiedContext` / `saveRuntimeSnapshot` to `loadRMSState` / `loadInsights`
2. delete `renderEpistemicSummary(_:)`
3. use `RMSSelector` + `RMSPromptComposer` directly
4. make `ClaudeService+AgenticLoop` construct the new dependencies instead of instantiating `MemoryRuntimeCoordinator`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopMemoryBootstrapComposer.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "refactor: switch bootstrap to new rms prompt path"
```

### Task 3: Build extraction, reduction, and task-bound RMS state persistence

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSExtractor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSReducer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/RMSInsightStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSExtractorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing tests**

Lock three runtime behaviors:

1. after each round, the loop updates the current task-bound `RMSState`
2. extractor produces `RMSInsightProposal` values only for `constraint` / `counterexample` / `tactic`
3. high-confidence proposals are written through `RMSInsightStore.upsert` immediately, with no job queue

示例测试形状：

```swift
@Test func roundCompletionUpdatesTaskBoundRMSStateWithoutBackgroundJobs() async throws {
    let extractor = StubRMSExtractor(result: .fixture(frontier: "Need build evidence"))
    let store = InMemoryRMSInsightStore()
    let runner = makeRunner(extractor: extractor, insightStore: store)

    let result = try await runner.runRoundFixture()

    #expect(result.rmsState.frontiers.map(\.openClaim) == ["Need build evidence"])
    #expect(store.upserted.count == 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSExtractorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because no RMS extraction/reduction path exists in the loop.

**Step 3: Implement the runtime state flow**

1. `RMSExtractor` consumes recent user/assistant/tool transcript plus prior `RMSState`
2. `RMSReducer` merges the delta deterministically
3. `AgentLoopRoundExecutor` or `AgentLoopRunner` updates the current task state after each completed round
4. write insights directly through `RMSInsightStore`
5. do not create any scheduler, queue, governance, or fallback runtime snapshot logic

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/RMSExtractor.swift agentGui/Services/RMSReducer.swift agentGui/Services/RMSInsightStore.swift agentGui/Services/AgentLoopRunner.swift agentGui/Services/AgentLoopRoundExecutor.swift agentGuiTests/RMSExtractorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "feat: add task-bound rms extraction and persistence"
```

### Task 4: Replace RMS UI and settings with the simplified product surface

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSPanelViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSPanel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RMSPanelViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsMemoryNavigationStateTests.swift`

**Step 1: Write the failing UI tests**

Lock these expectations:

1. the panel reads one current `RMSState`
2. the panel exposes only frontier / constraint / counterexample / verification debt / next actions
3. settings only expose `memoryEnabled` and `memoryContextBudget`
4. settings no longer expose `enableUnifiedMemoryRuntime`, `enableEpistemicExtraction`, `enableRMSRetrieval`, `enableRMSDistillation`, `enableMemoryGovernance`, `enableMemoryTTLSweep`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSPanelViewModelTests \
  -only-testing:agentGuiTests/SettingsMemoryNavigationStateTests
```

Expected: FAIL because the old cognition panel and old settings model are still wired in.

**Step 3: Implement the simplified UI surface**

1. create `RMSPanelViewModel` and `RMSPanel`
2. remove diagnostics-focused view model logic
3. rewrite `SettingsMemoryView` around two settings only
4. collapse `AppSettings` memory-related fields to `memoryEnabled` and `memoryContextBudget`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/RMSPanelViewModel.swift agentGui/Views/Memory/RMSPanel.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGui/Models/AppSettings.swift agentGuiTests/RMSPanelViewModelTests.swift agentGuiTests/SettingsMemoryNavigationStateTests.swift
git commit -m "refactor: replace rms ui and settings surface"
```

### Task 5: Delete the legacy RMS runtime and remove obsolete tests

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConfirmationWorkflowService.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConflictResolver.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DefaultMemoryAdmissionPolicy.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSCognitionPanel.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Delete: corresponding legacy tests listed in section 2

**Step 1: Write the failing deletion checks**

Before deleting, add or update one integration test that proves:

1. no legacy coordinator is referenced
2. no background memory job path is reachable
3. no legacy settings flags remain in the UI model

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/SettingsMemoryNavigationStateTests
```

Expected: FAIL because the old runtime still exists.

**Step 3: Delete the legacy implementation**

1. remove all compile references to the legacy memory runtime types
2. delete the files listed above
3. delete or rewrite obsolete tests instead of leaving them skipped

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove legacy rms runtime and tests"
```

### Task 6: Run full regression and quality smoke

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-15-rms-agent-first-replacement.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-15-rms-agent-first-replacement-implementation-plan.md`

**Step 1: Run targeted test suites**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSStateTests \
  -only-testing:agentGuiTests/RMSSelectorTests \
  -only-testing:agentGuiTests/RMSPromptComposerTests \
  -only-testing:agentGuiTests/RMSExtractorTests \
  -only-testing:agentGuiTests/RMSPanelViewModelTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/SettingsMemoryNavigationStateTests
```

Expected: PASS.

**Step 2: Run broader project smoke**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: no new failures introduced by the RMS replacement.

**Step 3: Update docs to match final state**

Check and update:

1. `docs/technical-spec/2026-03-15-rms-agent-first-replacement.md`
2. this implementation plan document

Document any scope adjustments discovered during implementation.

**Step 4: Commit**

```bash
git add docs/technical-spec/2026-03-15-rms-agent-first-replacement.md docs/plans/2026-03-15-rms-agent-first-replacement-implementation-plan.md
git commit -m "test: validate rms agent-first replacement"
```

## 4. Expected end state

- Agent loop 只依赖新 `RMSState` / `RMSInsight` 主链。
- memory bootstrap 只走 `RMSSelector + RMSPromptComposer`。
- UI 只展示当前 task 绑定的认知状态。
- settings 只保留 `memoryEnabled` 与 `memoryContextBudget`。
- 代码库中不再存在 legacy memory runtime coordinator、planner、governance、background scheduler、legacy cognition panel。
- 测试从“多开关、多阶段、多层次”收敛为“单主链、task-bound、agent-first”语义。

## 5. Execution handoff

Plan complete and saved to `docs/plans/2026-03-15-rms-agent-first-replacement-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?