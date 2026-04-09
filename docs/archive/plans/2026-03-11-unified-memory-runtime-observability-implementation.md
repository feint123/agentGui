# Unified Memory Runtime Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add per-run unified-memory runtime snapshots so users can inspect which memory records were considered, selected, excluded, and how the injected context is distributed by type.

**Architecture:** Keep the current `MemoryRuntimeCoordinator -> MemoryRuntimeContext` flow, but extend it to emit a structured runtime snapshot plus precomputed aggregates. Persist snapshots in the existing unified-memory filesystem area, link each snapshot to the originating `ToolCall`, and surface the data through a dedicated SwiftUI panel and a lightweight entry point in tool-call details.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Foundation JSON persistence, SwiftData models already used by chat/tool history, Swift Testing, `xcodebuild` on macOS.

---

## Implementation Notes

- 这份计划只实现“单轮运行时可观测性”，不改写记忆检索策略本身。
- 运行时快照应作为结构化数据保存，不能退化成控制台日志或字符串塞进 `ToolCall`。
- 先交付 `ToolCall` 入口，再考虑扩展到 `AgentRound` 或全局浏览；避免一开始把入口面做太重。
- 图表第一期使用 Swift Charts；“上下文负载占比”先用字符长度估算，并在 UI 中标注为估算。
- 按 TDD 执行：先锁定快照结构和聚合逻辑，再接持久化和 UI，最后补集成回归。
- 推荐在独立 worktree 中执行这份计划，避免与当前主分支并行改动互相污染。

## Proposed File Layout

**Create models and store:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeSnapshotStore.swift`

**Modify runtime and linkage:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Create view model and views:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`

**Create or expand tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-unified-memory-runtime-observability-requirements.md`

### Task 1: Define Runtime Snapshot Model And Store Contract

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeSnapshotStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`

**Step 1: Write the failing test**

新增测试，锁定 snapshot 的最小结构、聚合字段和 JSON 持久化契约。

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryRuntimeSnapshotStoreTests {
    @Test func storeRoundTripsSnapshotWithSelectedAndExcludedRecords() throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let snapshot = MemoryRuntimeSnapshot.fixture(
            sessionId: "s1",
            toolCallId: "tool-1",
            candidateCount: 4,
            selectedRecords: [
                .fixture(recordID: "selected-1", title: "Known failure", layer: .task, estimatedPromptChars: 32)
            ],
            excludedRecords: [
                .fixture(recordID: "excluded-1", title: "Old archive", layer: .semantic, exclusionReason: .archived)
            ]
        )

        try store.save(snapshot)
        let loaded = try #require(store.snapshot(id: snapshot.id))

        #expect(loaded.selectedRecords.count == 1)
        #expect(loaded.excludedRecords.first?.exclusionReason == .archived)
        #expect(loaded.metrics.selectedCount == 1)
        #expect(loaded.metrics.countBreakdowns[.layer]?["task"] == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeSnapshotStoreTests
```

Expected: FAIL because `MemoryRuntimeSnapshotStore` and `MemoryRuntimeSnapshot` do not exist.

**Step 3: Write minimal implementation**

实现最小模型和文件存储：

- `MemoryRuntimeSnapshot` 包含 request 摘要、plan、candidate/selected/excluded records、rendered prompt、聚合 metrics
- `MemoryRuntimeSnapshotRecord` 存储 record 摘要和估算字符数
- `MemoryRuntimeExclusionReason` 定义需求文档里的排除原因枚举
- `MemoryRuntimeSnapshotStore` 把快照写到 `~/.agentgui/unified-memory/runtime-snapshots.json`

```swift
struct MemoryRuntimeSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sessionId: String
    var threadId: String
    var workflowRunId: String?
    var toolCallId: String?
    var createdAt: Date
    var request: RequestSummary
    var plan: PlanSummary
    var selectedRecords: [MemoryRuntimeSnapshotRecord]
    var excludedRecords: [MemoryRuntimeSnapshotRecord]
    var renderedPrompt: String
    var metrics: Metrics
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryRuntimeSnapshot.swift agentGui/Services/MemoryRuntimeSnapshotStore.swift agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift
git commit -m "feat: add memory runtime snapshot model and store"
```

### Task 2: Teach MemoryRuntimeCoordinator To Produce Selection Traces

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`

**Step 1: Write the failing test**

给协调器补测试，要求它不仅返回 `records`，还返回筛选 trace，能说明哪些记录因预算或归档被排除。

```swift
@Test func coordinatorBuildsSnapshotTraceWithBudgetAndExclusionReasons() async throws {
    let records = [
        MemoryRecord.fixture(id: "task-1", layer: .task, scope: .session(id: "s1"), title: "Hot fact", verificationStatus: .verified),
        MemoryRecord.fixture(id: "task-2", layer: .task, scope: .session(id: "s1"), title: "Cold fact", verificationStatus: .unverified),
        MemoryRecord.fixture(id: "semantic-archive", layer: .semantic, scope: .user, title: "Old pref", retentionPolicy: .archiveOnly)
    ]

    let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: records, storyRecords: [])
    let request = MemoryRuntimeRequest(sessionId: "s1", threadId: "t1", workflowRunId: nil, userRequest: "Fix build", taskKind: .coding, projectId: nil, workspaceRoot: "/tmp/repo", contextBudget: 1000)

    let context = try await coordinator.prepareContext(for: request)

    let snapshot = try #require(context.runtimeSnapshot)
    #expect(snapshot.selectedRecords.count == 1)
    #expect(snapshot.excludedRecords.contains { $0.recordID == "task-2" && $0.exclusionReason == .budgetTrimmed })
    #expect(snapshot.excludedRecords.contains { $0.recordID == "semantic-archive" && $0.exclusionReason == .archived })
    #expect(snapshot.plan.itemBudgetByLayer[.task] == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because `MemoryRuntimeContext` has no `runtimeSnapshot`, and the coordinator does not compute exclusion traces.

**Step 3: Write minimal implementation**

把协调器拆成可追踪阶段：

- 在 `MemoryRuntimeContext` 增加 `runtimeSnapshot: MemoryRuntimeSnapshot?`
- 在 `prepareContext(for:)` 里分别计算 candidate、allowed、sorted、selected、excluded
- 为每条 excluded record 写入原因
- 在 snapshot 中记录 per-layer `candidateCount / selectedCount / budget`
- `estimatedPromptChars` 先基于 `title + summary` 的字符数估算

```swift
struct MemoryRuntimeContext: Equatable, Sendable {
    var profiles: [String]
    var records: [MemoryRecord]
    var writePolicy: MemoryWritePolicy
    var warnings: [String]
    var renderedPrompt: String
    var runtimeSnapshot: MemoryRuntimeSnapshot?
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/MemoryRuntimeTypes.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: trace memory runtime selection and exclusions"
```

### Task 3: Persist Snapshots And Link Them To Tool Calls

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeSnapshotStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing test**

新增集成测试，锁定统一记忆启用时会把 snapshot 保存下来，并把 snapshot ID 写入工具调用元数据。

```swift
@Test func unifiedMemoryBootstrapPersistsSnapshotAndLinksToolCall() async throws {
    let baseDirectory = try makeTemporaryDirectory()
    let store = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
    let coordinator = MemoryRuntimeCoordinator.makeForTests(
        unifiedRecords: [MemoryRecord.fixture(id: "task-1", layer: .task, scope: .session(id: "s1"), title: "Known failure")],
        storyRecords: []
    )

    let context = try await coordinator.prepareContext(for: .init(sessionId: "s1", threadId: "t1", workflowRunId: nil, userRequest: "Fix build", taskKind: .coding, projectId: nil, workspaceRoot: "/tmp/repo", contextBudget: 4000))
    let snapshot = try #require(context.runtimeSnapshot)
    try store.save(snapshot)

    let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
    toolCall.memoryRuntimeSnapshotID = snapshot.id

    #expect(try store.snapshot(id: snapshot.id)?.selectedRecords.count == 1)
    #expect(toolCall.memoryRuntimeSnapshotID == snapshot.id)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because `ToolCall` has no snapshot ID field and the agent loop does not persist snapshots.

**Step 3: Write minimal implementation**

实现主链路对接：

- 在 `ToolCall` 新增 `memoryRuntimeSnapshotID: String?`
- 在 `ClaudeService+AgenticLoop` 的 unified memory bootstrap 之后，若有 snapshot 则调用 `MemoryRuntimeSnapshotStore.save(snapshot)`
- 创建工具调用记录时，把 `memoryRuntimeSnapshotID` 写进去
- 若本轮无记录但统一记忆已启用，也保存一份 `selectedCount = 0` 的空快照，保证 UI 可解释

```swift
if let snapshot = unifiedContext?.runtimeSnapshot {
    try? snapshotStore.save(snapshot)
    record.memoryRuntimeSnapshotID = snapshot.id
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/MemoryRuntimeSnapshotStore.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "feat: persist runtime snapshots and link tool calls"
```

### Task 4: Build Snapshot ViewModel Aggregates For Charts And Lists

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`

**Step 1: Write the failing test**

新增 ViewModel 测试，锁定 chart/list 所需的分组切换和口径切换。

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryRuntimeSnapshotViewModelTests {
    @Test func viewModelBuildsCountAndLoadBreakdownsForSelectedRecords() throws {
        let snapshot = MemoryRuntimeSnapshot.fixture(
            selectedRecords: [
                .fixture(recordID: "r1", title: "Known failure", layer: .task, kind: .working, estimatedPromptChars: 40, verificationStatus: .verified),
                .fixture(recordID: "r2", title: "User pref", layer: .semantic, kind: .semantic, estimatedPromptChars: 10, verificationStatus: .verified),
                .fixture(recordID: "r3", title: "Speculative cause", layer: .task, kind: .working, estimatedPromptChars: 20, verificationStatus: .unverified)
            ]
        )

        let viewModel = MemoryRuntimeSnapshotViewModel(snapshot: snapshot)
        viewModel.dimension = .layer
        viewModel.metric = .estimatedChars

        #expect(viewModel.chartItems.contains { $0.label == "task" && $0.value == 60 })
        #expect(viewModel.chartItems.contains { $0.label == "semantic" && $0.value == 10 })
        #expect(viewModel.selectedSummary.selectedCount == 3)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeSnapshotViewModelTests
```

Expected: FAIL because `MemoryRuntimeSnapshotViewModel` does not exist.

**Step 3: Write minimal implementation**

实现只读 ViewModel：

- 支持 `dimension = layer / kind / scope / verificationStatus / source`
- 支持 `metric = count / estimatedChars`
- 产出图表数据、layer budget 行数据、selected/excluded 列表的过滤结果
- 提供 prompt 摘要长度、候选数、入选数、排除数等摘要字段

```swift
@MainActor
@Observable
final class MemoryRuntimeSnapshotViewModel {
    enum Dimension { case layer, kind, scope, verificationStatus, source }
    enum Metric { case count, estimatedChars }

    var dimension: Dimension = .layer
    var metric: Metric = .count
    let snapshot: MemoryRuntimeSnapshot

    var chartItems: [ChartItem] { /* aggregate selectedRecords here */ }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift
git commit -m "feat: add runtime snapshot view model aggregates"
```

### Task 5: Add Snapshot Panel With Charts, Budget Rows, And Record Lists

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

**Step 1: Write the failing test**

先锁定工具详情里会出现 snapshot 入口摘要，而不是只显示 `Profiles/Layers/Warnings`。

```swift
import Foundation
import Testing
@testable import agentGui

struct ToolCallDetailPresentationTests {
    @Test func detailSectionsIncludeSnapshotEntryWhenSnapshotIDExists() {
        let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
        toolCall.memoryRuntimeProfiles = ["coding-task"]
        toolCall.memoryRuntimeSnapshotID = "snapshot-1"

        let row = ToolCallRowPresentation(style: .search, title: "搜索", subtitle: nil, detailText: nil, tertiaryText: nil, statusText: nil, accent: .secondary)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.contains { $0.label == "记忆上下文快照" && $0.text.contains("snapshot-1") })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: FAIL because no snapshot section or UI exists.

**Step 3: Write minimal implementation**

分三块实现：

- `MemoryRuntimeSnapshotPanel`：摘要栏、图表栏、预算栏、入选/排除列表、prompt 预览
- `MemoryRuntimeSnapshotCharts`：使用 `Chart`, `SectorMark`, `BarMark` 展示占比和 per-layer budget
- `ToolCallDetailContentView`：增加 snapshot section 和“查看快照”入口；第一期可用 `sheet` 打开 panel

```swift
import Charts
import SwiftUI

struct MemoryRuntimeSnapshotPanel: View {
    @State var viewModel: MemoryRuntimeSnapshotViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummarySection(viewModel: viewModel)
                MemoryRuntimeSnapshotCharts(viewModel: viewModel)
                MemoryRuntimeSnapshotRecordList(title: "入选记录", records: viewModel.selectedRecords)
                MemoryRuntimeSnapshotRecordList(title: "排除记录", records: viewModel.excludedRecords)
                PromptPreviewSection(text: viewModel.snapshot.renderedPrompt)
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "feat: surface runtime snapshot panel from tool details"
```

### Task 6: Add End-To-End Coverage For Empty And Non-Empty Snapshot Flows

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-unified-memory-runtime-observability-requirements.md`

**Step 1: Write the failing test**

补两条关键回归：

- 命中记录时，snapshot 包含 selected records、图表 metrics 和 rendered prompt
- 未命中记录时，也有空 snapshot，且 `selectedCount == 0`，供 UI 展示空态

```swift
@Test func emptyUnifiedMemorySliceStillProducesInspectableSnapshot() async throws {
    let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: [], storyRecords: [])
    let request = MemoryRuntimeRequest(sessionId: "s1", threadId: "t1", workflowRunId: nil, userRequest: "Fix build", taskKind: .coding, projectId: nil, workspaceRoot: "/tmp/repo", contextBudget: 4000)

    let context = try await coordinator.prepareContext(for: request)
    let snapshot = try #require(context.runtimeSnapshot)

    #expect(snapshot.metrics.selectedCount == 0)
    #expect(snapshot.selectedRecords.isEmpty)
    #expect(snapshot.request.contextBudget == 4000)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because empty-flow snapshots are not yet guaranteed end-to-end.

**Step 3: Write minimal implementation**

修正主链路的边界行为：

- `prepareContext(for:)` 始终生成 snapshot
- `buildUnifiedMemoryBootstrap` 不再以“records 为空”作为完全跳过可观测性的条件
- snapshot metrics 对空集返回稳定值，不产生除零或缺字段问题

```swift
let context = MemoryRuntimeContext(
    profiles: profileIDs,
    records: selectedRecords,
    writePolicy: writePolicy,
    warnings: warnings,
    renderedPrompt: prompt,
    runtimeSnapshot: snapshot
)
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGui/Services/ClaudeService+AgenticLoop.swift
git commit -m "test: cover empty and populated memory runtime snapshots"
```

### Task 7: Final Verification And Documentation Sync

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md` (only if runtime observability is user-visible enough to mention)
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-unified-memory-runtime-observability-requirements.md`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-unified-memory-runtime-observability-implementation.md`

**Step 1: Write the failing test**

这里不新增功能测试；改为先列出最终必须通过的测试清单，确保没有遗漏回归范围。

```text
Required test set:
- agentGuiTests/MemoryRuntimeSnapshotStoreTests
- agentGuiTests/MemoryRuntimeCoordinatorTests
- agentGuiTests/MemoryRuntimeIntegrationTests
- agentGuiTests/MemoryRuntimeSnapshotViewModelTests
- agentGuiTests/ToolCallDetailPresentationTests
```

**Step 2: Run test to verify current status**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeSnapshotStoreTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryRuntimeSnapshotViewModelTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: PASS for all targeted tests.

**Step 3: Write minimal implementation**

若有 README 更新需要，只补一段简述：

- 统一记忆运行时现在可查看每轮上下文快照
- 图表显示按类型的条目占比和字符占比
- 空命中轮次也可查看，避免误判系统未启用

```md
- Unified Memory Runtime now exposes per-run context snapshots from tool details, including selected records, excluded reasons, and count/character-based breakdown charts.
```

**Step 4: Run test to verify it passes**

重复上面的 targeted `xcodebuild` 命令。

Expected: PASS.

**Step 5: Commit**

```bash
git add README.md agentGui/Models/MemoryRuntimeSnapshot.swift agentGui/Services/MemoryRuntimeSnapshotStore.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Models/MemoryRuntimeTypes.swift agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotCharts.swift agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/MemoryRuntimeSnapshotStoreTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "feat: add unified memory runtime observability"
```

## Execution Handoff

Plan complete and saved to `docs/plans/2026-03-11-unified-memory-runtime-observability-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?