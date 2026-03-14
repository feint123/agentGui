# RMS Memory UI Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用一个面向用户的 `RMS 认知面板` 替换当前治理/快照型 memory UI，并从产品主路径中删除现有 memory 相关视图和入口。

**Architecture:** 采用替换式迁移，而不是在旧治理面板上继续叠加。第一阶段先建立把 `EpistemicState` 和 `MemoryInfluenceTrace` 投影为用户可理解 UI section 的 view model 与 panel；第二阶段替换设置页路由和产品入口；第三阶段删除旧的治理/快照视图、旧 view model 与对应测试，并保留必要的底层服务但不再暴露为主产品界面。

**Tech Stack:** Swift 6、SwiftUI、Observation、现有 `EpistemicState` / `MemoryInfluenceTrace` / `MemoryRuntimeSnapshot` 模型、Swift Testing、`xcodebuild`、`./scripts/run_quality_smoke.sh`。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 约束与决策

### 必须满足的约束

1. 新 UI 的主叙事必须是 RMS 认知对象，而不是 record store、治理队列或 snapshot 运营指标。
2. `Frontiers`、`Counterexamples`、`Constraints`、`Verification Debt`、`Influence Trace`、`Suggested Next Actions` 必须成为一等 section。
3. 旧视图不做兼容保留，不再提供双轨入口。
4. 调试信息如果保留，只能作为折叠的 secondary details，不能占据第一屏。
5. 实现顺序必须先建立新 panel，再删除旧 panel，避免设置页出现空路由。

### 当前涉及入口

本计划基于以下现有对象展开：

1. 旧主界面：`agentGui/Views/Memory/MemoryManagementPanel.swift`
2. 旧快照界面：`agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
3. 旧快照子视图：`agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift`、`agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
4. 旧治理子视图：`agentGui/Views/Memory/MemoryConflictList.swift`、`agentGui/Views/Memory/MemoryConfirmationList.swift`
5. 旧 view model：`agentGui/ViewModels/MemoryManagementViewModel.swift`、`agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
6. 设置页入口：`agentGui/Views/Settings/SettingsMemoryView.swift`
7. 设置路由：`agentGui/Views/Settings/SettingsDetailRoute.swift`、`agentGui/Views/Settings/SettingsStore.swift`、`agentGui/Views/Settings/SettingsWindowView.swift`
8. 工具详情：`agentGui/Views/ToolCallDetailContentView.swift`

### 推荐方案

推荐方案是：`单一 RMS 认知面板 + 次级调试 disclosure + 删除旧治理/快照 UI`。

原因：需求文档已经明确当前问题是信息架构错位，而不是缺少更多运营视图。继续保留 `MemoryManagementPanel` 或 `MemoryRuntimeSnapshotPanel` 作为次入口，只会把 store-centric 语义继续留在产品里。

## 1. 交付门槛

### Gate A：新语义可视化成立

1. 新 panel 第一屏直接展示 frontiers / counterexamples / constraints / debt / influence / next actions。
2. 用户无需理解 layer、scope、candidate trimming 等术语，也能理解 memory 对当前任务的作用。

### Gate B：旧 UI 主路径消失

1. 设置页不再打开 `MemoryManagementPanel`。
2. 产品路由中不再存在 `memoryGovernance` 这一旧界面语义。
3. 旧治理/快照视图文件与对应 view model 已从主代码路径删除。

### Gate C：质量门槛

1. 新 view model 测试覆盖主要 RMS section 投影逻辑。
2. 旧 memory UI 测试已替换或删除，不再断言治理/快照面板行为。
3. `Quality Smoke` 通过。

## 2. 实施任务

### Task 1: 建立 RMS 认知面板的投影模型与 view model

**Files:**
- Create: `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`
- Reference: `agentGui/Models/EpistemicState.swift`
- Reference: `agentGui/Models/MemoryInfluenceTrace.swift`
- Reference: `agentGui/Models/MemoryRuntimeSnapshot.swift`

**Step 1: Write the failing tests**

先锁定新 view model 的核心职责：它把 runtime 状态投影成用户语义 section，而不是 record store 统计。

```swift
import Testing
@testable import agentGui

@MainActor
struct RMSCognitionPanelViewModelTests {
    @Test func viewModelProjectsFrontiersCounterexamplesConstraintsAndDebt() {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need scheme evidence",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ],
                counterexamples: [
                    CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")
                ],
                activeConstraints: [
                    ConstraintMemory(id: "c-1", summary: "Run verification before file edits", scope: .session(id: "s1"))
                ],
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Build fix works", reason: "No direct test evidence yet")
                ],
                candidateActions: ["Run xcodebuild -list"]
            )
        )

        let viewModel = RMSCognitionPanelViewModel(snapshot: snapshot)

        #expect(viewModel.frontierItems.count == 1)
        #expect(viewModel.counterexampleItems.count == 1)
        #expect(viewModel.constraintItems.count == 1)
        #expect(viewModel.verificationDebtItems.count == 1)
        #expect(viewModel.suggestedActionItems.map(\.summary) == ["Run xcodebuild -list"])
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests
```

Expected: FAIL because `RMSCognitionPanelViewModel` does not exist.

**Step 3: Write minimal implementation**

实现最小 view model：

1. 接收 `MemoryRuntimeSnapshot`
2. 暴露 `frontierItems`、`counterexampleItems`、`constraintItems`、`verificationDebtItems`、`influenceItems`、`suggestedActionItems`
3. 提供少量用户文案型 summary，而不是底层 metrics 聚合

```swift
@MainActor
@Observable
final class RMSCognitionPanelViewModel {
    let snapshot: MemoryRuntimeSnapshot

    init(snapshot: MemoryRuntimeSnapshot) {
        self.snapshot = snapshot
    }

    var frontierItems: [FrontierItem] { ... }
    var counterexampleItems: [CounterexampleItem] { ... }
    var constraintItems: [ConstraintItem] { ... }
    var verificationDebtItems: [VerificationDebtItem] { ... }
    var influenceItems: [InfluenceItem] { ... }
    var suggestedActionItems: [SuggestedActionItem] { ... }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift
git commit -m "feat: add rms cognition panel view model"
```

### Task 2: 实现新的 RMS 认知面板与 section 视图

**Files:**
- Create: `agentGui/Views/Memory/RMSCognitionPanel.swift`
- Create: `agentGui/Views/Memory/RMSCognitionHeroSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionFrontierSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionCounterexampleSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionConstraintSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionVerificationDebtSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionInfluenceSection.swift`
- Create: `agentGui/Views/Memory/RMSCognitionNextActionsSection.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`

**Step 1: Write the failing test**

先锁定面板是否按照需求文档的 section 顺序组织数据。

```swift
@Test func viewModelExposesSectionsInUserFacingOrder() {
    let snapshot = MemoryRuntimeSnapshot.fixture(epistemicState: EpistemicState())
    let viewModel = RMSCognitionPanelViewModel(snapshot: snapshot)

    #expect(viewModel.sectionOrder == [
        .frontiers,
        .counterexamples,
        .constraints,
        .verificationDebt,
        .influenceTrace,
        .suggestedActions
    ])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests
```

Expected: FAIL because `sectionOrder` and the new panel structure do not exist.

**Step 3: Write minimal implementation**

实现新 panel：

1. 顶部 hero 区说明当前认知状态
2. 六个 section 按需求文档顺序排列
3. 调试信息只出现在折叠 disclosure 中
4. 不再显示 layer budgets、record rows、rollout flags、prompt preview

```swift
struct RMSCognitionPanel: View {
    @State var viewModel: RMSCognitionPanelViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RMSCognitionHeroSection(viewModel: viewModel)
                RMSCognitionFrontierSection(items: viewModel.frontierItems)
                RMSCognitionCounterexampleSection(items: viewModel.counterexampleItems)
                RMSCognitionConstraintSection(items: viewModel.constraintItems)
                RMSCognitionVerificationDebtSection(items: viewModel.verificationDebtItems)
                RMSCognitionInfluenceSection(items: viewModel.influenceItems)
                RMSCognitionNextActionsSection(items: viewModel.suggestedActionItems)
            }
            .padding(24)
        }
        .navigationTitle("RMS 认知面板")
    }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Memory/RMSCognitionPanel.swift agentGui/Views/Memory/RMSCognitionHeroSection.swift agentGui/Views/Memory/RMSCognitionFrontierSection.swift agentGui/Views/Memory/RMSCognitionCounterexampleSection.swift agentGui/Views/Memory/RMSCognitionConstraintSection.swift agentGui/Views/Memory/RMSCognitionVerificationDebtSection.swift agentGui/Views/Memory/RMSCognitionInfluenceSection.swift agentGui/Views/Memory/RMSCognitionNextActionsSection.swift agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift
git commit -m "feat: add rms cognition panel ui"
```

### Task 3: 替换设置页入口与路由语义

**Files:**
- Modify: `agentGui/Views/Settings/SettingsDetailRoute.swift`
- Modify: `agentGui/Views/Settings/SettingsStore.swift`
- Modify: `agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `agentGui/Views/Settings/SettingsMemoryView.swift`
- Test: `agentGuiTests/MemoryRuntimeSettingsTests.swift`

**Step 1: Write the failing test**

锁定设置页入口已经从“治理”迁移到“认知面板”语义。

```swift
@Test func settingsStoreShowsRMSCognitionRoute() {
    let store = SettingsStore.previewFixture()
    store.showRMSCognitionPanel()

    #expect(store.detailPath == [.rmsCognition])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeSettingsTests
```

Expected: FAIL because the route and helper do not exist.

**Step 3: Write minimal implementation**

实现替换：

1. `SettingsDetailRoute.memoryGovernance` 改为 `SettingsDetailRoute.rmsCognition`
2. `SettingsStore.showMemoryGovernance()` 改为 `showRMSCognitionPanel()`
3. `SettingsWindowView` 打开 `RMSCognitionPanel`
4. `SettingsMemoryView` 的入口文案改为“打开 RMS 认知面板”

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsDetailRoute.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGuiTests/MemoryRuntimeSettingsTests.swift
git commit -m "refactor: route settings memory entry to rms cognition panel"
```

### Task 4: 删除旧的治理/快照视图和旧 view model

**Files:**
- Delete: `agentGui/Views/Memory/MemoryManagementPanel.swift`
- Delete: `agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- Delete: `agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift`
- Delete: `agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- Delete: `agentGui/Views/Memory/MemoryConflictList.swift`
- Delete: `agentGui/Views/Memory/MemoryConfirmationList.swift`
- Delete: `agentGui/ViewModels/MemoryManagementViewModel.swift`
- Delete: `agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- Modify: `agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `agentGuiTests/ToolCallDetailPresentationTests.swift`
- Delete or Replace: `agentGuiTests/MemoryManagementViewModelTests.swift`
- Delete or Replace: `agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`

**Step 1: Write the failing tests**

新增针对新 panel 的测试，替代旧 view model 测试；同时锁定工具详情不再暴露旧 snapshot UI 语义。

```swift
@Test func detailSectionsStillHideMemoryAuditPanels() {
    let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
    let row = ToolCallRowPresentation.make(for: toolCall)
    let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

    #expect(!sections.contains { $0.label == "RMS 治理" })
    #expect(!sections.contains { $0.label == "记忆上下文快照" })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests
```

Expected: FAIL until the old references and tests are cleaned up.

**Step 3: Write minimal implementation**

执行删除：

1. 删除所有旧 memory panel / snapshot panel / chart / record list / conflict / confirmation 视图
2. 删除旧 `MemoryManagementViewModel` 与 `MemoryRuntimeSnapshotViewModel`
3. 确保 `ToolCallDetailContentView` 不再提供旧 memory panel 相关说明或扩展入口
4. 用新 `RMSCognitionPanelViewModelTests` 替代旧 UI 语义测试

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/ToolCallDetailPresentationTests.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift
git rm agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift agentGui/Views/Memory/MemoryConflictList.swift agentGui/Views/Memory/MemoryConfirmationList.swift agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGuiTests/MemoryManagementViewModelTests.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift
git commit -m "refactor: remove legacy memory governance and snapshot views"
```

### Task 5: 为新 panel 增加次级调试信息，但不恢复旧快照主叙事

**Files:**
- Modify: `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Modify: `agentGui/Views/Memory/RMSCognitionPanel.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`

**Step 1: Write the failing test**

锁定调试信息存在，但不会抢占主界面。

```swift
@Test func viewModelExposesDeveloperDiagnosticsAsSecondaryDetails() {
    let snapshot = MemoryRuntimeSnapshot.fixture(workingSetCost: 128)
    let viewModel = RMSCognitionPanelViewModel(snapshot: snapshot)

    #expect(viewModel.developerDiagnostics.workingSetCost == 128)
    #expect(viewModel.showDeveloperDiagnosticsByDefault == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests
```

Expected: FAIL because the diagnostics disclosure model does not exist.

**Step 3: Write minimal implementation**

实现一个折叠的“开发调试信息”区域，仅包含：

1. working-set cost
2. bridge expansion count
3. dereference count
4. retrieval intent summary

默认收起，且不再展示 candidate / selected / excluded records。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGui/Views/Memory/RMSCognitionPanel.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift
git commit -m "feat: add secondary diagnostics to rms cognition panel"
```

### Task 6: 更新文档与测试基线，完成 UI 替换收口

**Files:**
- Modify: `docs/spec/2026-03-14-rms-memory-ui-redesign-requirements.md`
- Modify: `docs/technical-spec/2026-03-10-agent-architecture.md`
- Modify: `docs/spec/2026-03-11-unified-memory-runtime-observability-requirements.md`
- Modify: `agentGuiTests/ToolCallDetailPresentationTests.swift`
- Optional Delete or Update: 任何仅描述旧治理/快照 UI 的测试或文档

**Step 1: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/MemoryRuntimeSettingsTests
```

Expected: PASS.

**Step 2: Run smoke validation**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 3: Update docs**

把旧 `MemoryManagementPanel` / `MemoryRuntimeSnapshotPanel` 在技术文档中的产品描述替换为 `RMSCognitionPanel`，并明确旧 UI 已移除。

**Step 4: Commit**

```bash
git add docs/spec/2026-03-14-rms-memory-ui-redesign-requirements.md docs/technical-spec/2026-03-10-agent-architecture.md docs/spec/2026-03-11-unified-memory-runtime-observability-requirements.md agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "docs: finalize rms memory ui replacement"
```

## 3. 实施注意事项

1. 不要在旧 `MemoryManagementPanel` 上做局部改造后长期保留同名视图。目标是替换，不是换皮。
2. 不要把 record breakdown、layer budget、selected/excluded records 偷偷塞回新 panel 主视图。
3. 不要把 approval/reject 流程继续当作用户主界面能力；它们如果仍需保留，只能留在内部服务或次级调试路径。
4. 不要让 `RMSCognitionPanelViewModel` 直接访问 store；它应基于 runtime snapshot 和 epistemic state 做投影。
5. 不要在第一版中同时做“独立 panel + 全量内联消息改造”。先稳定单一面板。

## 4. 完成定义

满足以下条件才算完成：

1. 产品主路径中旧的治理/快照 memory UI 已被删除。
2. 设置页打开的是 `RMS 认知面板`，而不是旧治理面板。
3. 新界面第一屏能直接解释当前未决前沿、反例、约束、验证债务与下一步动作。
4. 调试信息降级为次级 disclosure，而不是主界面主体。
5. 相关测试与 `Quality Smoke` 通过。