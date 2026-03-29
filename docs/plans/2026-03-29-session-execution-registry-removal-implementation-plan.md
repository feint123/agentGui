# Session Execution Registry Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove `SessionExecutionRegistry` and `SessionExecutionController` from the app layer so `ExecutionProjectionStore` becomes the only session execution presentation source for workspace state and session-facing UI.

**Architecture:** Keep `ExecutionProjectionStore` as the single published projection holder introduced by Feature 1, and replace the remaining registry compatibility layer with a thin store-backed access path on `WorkspaceState` or an equally small projection facade. `WorkbenchShellView` should bind the shared store once, `WorkspaceState.selectedSession` should publish foreground/background presentation changes through store events, and UI surfaces such as `SessionListView` must read projections directly from the store-backed path rather than through controller caches.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing execution projection subsystem (`ExecutionProjectionStore`, `SessionExecutionProjectionReducer`, `ConversationExecutionRuntimeCoordinator`).

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来编写这份 implementation plan。
- 这份计划只覆盖 Feature 2，不提前实现 Feature 3 的 runtime truth 下沉，也不为删除 registry 再新增一个等价兼容层。
- 全程按 @test-driven-development 执行：先锁回归，再写最小实现，再跑 focused tests，再提交。
- 删除优先于重命名；如果某个能力已经可以由 `ExecutionProjectionStore` 或 `WorkspaceState` 的薄 facade 直接承担，就不要保留 `SessionExecutionRegistry` 风格的中间对象。
- `ChatView` 已经直接读取 `claudeService.executionProjectionStore`，Feature 2 不要把它改回 `WorkspaceState` 间接读取；本轮主要清理剩余 legacy consumer。
- 命令面板需要做 consumer audit，但当前 `AppCommandContext` 只传 `WorkspaceState`，并不直接读取 `executionRegistry`；如果审计结果仍然成立，就不要为命令面板制造额外改动。
- 删除 Swift 文件和测试文件时，必须同步清理 `agentGui.xcodeproj/project.pbxproj` 里的 file reference / build phase 条目，否则会留下工程级编译噪音。
- 全部任务完成后，用 @requesting-code-review 做一次 focused review，重点检查：应用层是否完全不再持有 `executionRegistry`、UI 是否只读 store/facade、legacy tests 与工程引用是否删除干净。

## 2. Current State Summary

- `WorkspaceState` 当前默认持有 `SessionExecutionRegistry`，并在 `selectedSession.didSet` 里调用 `executionRegistry.setForegroundSession(...)`。
- `WorkbenchShellView.configureOnAppear()` 会重新构造一个绑定 `claudeService.executionProjectionStore` 的 registry，再回填给 `WorkspaceState`。
- `SessionListView` 仍然通过 `workspaceState.executionRegistry.projection(for:)` 读取会话执行态；这是当前最直接的 registry UI consumer。
- `ChatView` 已经直接读取 `claudeService.executionProjectionStore.projection(for:)`，说明 Feature 2 可以沿用 direct-store 模型，而不是继续扩展 registry。
- `SessionExecutionRegistryTests`、`SessionExecutionControllerTests`、`WorkspaceStateTests` 目前锁定的是 registry/controller 行为；Feature 2 需要把这些回归测试改写成“无 registry 仍然正确”的测试。
- `AppCommandContext` / 命令面板链路目前不直接依赖 registry，Feature 2 只需要确认这一点持续成立，不需要主动改造命令面板结果模型。

## 3. Desired End State

完成后应满足以下条件：

1. `WorkspaceState` 不再暴露 `executionRegistry`，只保留 store-backed execution projection 访问能力与 foreground selection 发布能力。
2. `WorkbenchShellView` 不再创建或注入 `SessionExecutionRegistry`；它只把共享 `ExecutionProjectionStore` 绑定到 app state / environment。
3. `SessionListView` 和其余执行态 UI 只读取 `ExecutionProjectionStore` 或一个不带缓存写回职责的薄 facade。
4. `SessionExecutionRegistry.swift`、`SessionExecutionController.swift`、对应测试文件，以及 Xcode 工程里的相关引用全部删除。
5. 仓库内对 `executionRegistry`、`SessionExecutionRegistry`、`SessionExecutionController` 的引用仅允许存在于历史文档与计划文档，不再存在于 `agentGui`、`agentGuiTests` 或 `agentGui.xcodeproj/project.pbxproj` 的生产/测试代码中。

## 4. Target Files

### Primary production files

- `agentGui/Utilities/WorkspaceState.swift`
- `agentGui/Views/Workbench/WorkbenchShellView.swift`
- `agentGui/Views/SessionListView.swift`
- `agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `agentGui.xcodeproj/project.pbxproj`

### Files to delete

- `agentGui/Services/Execution/SessionExecutionRegistry.swift`
- `agentGui/Services/Execution/SessionExecutionController.swift`
- `agentGuiTests/SessionExecutionRegistryTests.swift`
- `agentGuiTests/SessionExecutionControllerTests.swift`

### Primary tests to modify

- `agentGuiTests/WorkspaceStateTests.swift`
- `agentGuiTests/ExecutionProjectionStoreTests.swift`
- `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`
- `agentGuiTests/ChatComposerExecutionPresentationTests.swift`

### Audit-only files

- `agentGui/AppCommands/Core/AppCommandContext.swift`
- `agentGui/AppCommands/Palette/QuickOpenProvider.swift`
- `agentGui/AppCommands/Palette/CommandPaletteViewModel.swift`
- `agentGui/Views/ChatView.swift`

## 5. Task Breakdown

### Task 1: 把 WorkspaceState 改成 store-backed execution projection facade

**Files:**
- Modify: `agentGui/Utilities/WorkspaceState.swift`
- Modify: `agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing test**

把 `WorkspaceStateTests` 从 registry 语义改成 store-backed 语义，至少覆盖这 3 条路径：

```swift
@Test
func selectingSessionPublishesForegroundPresentationWithoutRegistry() {
    let store = ExecutionProjectionStore()
    let workspaceState = WorkspaceState()
    workspaceState.bindExecutionProjectionStore(store)

    let first = Session.fixture(sessionId: "session-a")
    let second = Session.fixture(sessionId: "session-b")

    store.apply(.started(sessionID: first.sessionId, jobID: UUID(), providerReference: .builtIn))
    store.apply(.started(sessionID: second.sessionId, jobID: UUID(), providerReference: .builtIn))

    workspaceState.selectedSession = first
    workspaceState.selectedSession = second

    #expect(store.projection(for: first.sessionId).presentationState == .background)
    #expect(store.projection(for: second.sessionId).presentationState == .foreground)
}

@Test
func executionProjectionAccessInvalidatesWhenStoreChanges() {
    let store = ExecutionProjectionStore()
    let workspaceState = WorkspaceState()
    workspaceState.bindExecutionProjectionStore(store)

    var invalidationCount = 0
    withObservationTracking {
        _ = workspaceState.executionProjection(for: "session-observed")
    } onChange: {
        invalidationCount += 1
    }

    store.apply(.presentationChanged(sessionID: "session-observed", state: .background))

    #expect(invalidationCount == 1)
}

@Test
func unboundProjectionAccessFallsBackToEmptyProjection() {
    let workspaceState = WorkspaceState()
    let projection = workspaceState.executionProjection(for: "session-a")

    #expect(projection == .empty(sessionID: "session-a"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature2-task1 -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `WorkspaceState` still exposes `executionRegistry`, and the new store-backed API does not exist yet.

**Step 3: Write minimal implementation**

在 `WorkspaceState` 里做最小收敛：

- 删除 `var executionRegistry = SessionExecutionRegistry()`。
- 新增一个 `@ObservationIgnored` 的 `ExecutionProjectionStore` 引用或等价绑定点，例如 `private(set) var executionProjectionStore: ExecutionProjectionStore?`。
- 新增 `bindExecutionProjectionStore(_:)` 或等价初始化注入 API，统一绑定共享 store。
- 新增 `executionProjection(for:) -> SessionExecutionProjection`，直接从 store 读 projection；未绑定时返回 `.empty(sessionID:)`。
- 把 `selectedSession.didSet` 改成直接通过 store 发布 `.presentationChanged` 事件，遍历 `store.projections.keys` 更新已知 session 的 foreground/background 状态，不再依赖 registry/controller cache。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command again.

Expected: PASS, 且 `WorkspaceState` 已经不再需要 registry 才能同步 foreground presentation。

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkspaceState.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "refactor: bind workspace execution state to projection store"
```

### Task 2: 迁移 shell 和会话列表 consumer 到 direct-store / facade

**Files:**
- Modify: `agentGui/Views/Workbench/WorkbenchShellView.swift`
- Modify: `agentGui/Views/SessionListView.swift`
- Modify: `agentGui/Utilities/WorkspaceState.swift`
- Modify: `agentGuiTests/WorkspaceStateTests.swift`
- Modify: `agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing test**

先补 2 个“无 registry 仍正确”的回归约束：

```swift
@Test
func bindingProjectionStoreSeedsForegroundSelectionFromCurrentSession() {
    let store = ExecutionProjectionStore()
    let workspaceState = WorkspaceState()
    let selected = Session.fixture(sessionId: "session-selected")
    workspaceState.selectedSession = selected

    store.apply(.started(sessionID: selected.sessionId, jobID: UUID(), providerReference: .builtIn))
    workspaceState.bindExecutionProjectionStore(store)

    #expect(workspaceState.executionProjection(for: selected.sessionId).presentationState == .foreground)
}

@Test
func executionProjectionUiContractStillUsesStoreBackedProjection() {
    let projection = SessionExecutionProjection.fixture(
        sessionID: "session-a",
        runningJobID: UUID(),
        activityState: .running,
        presentationState: .background
    )

    #expect(ChatComposerExecutionPresentation.shouldUseExecutionProjectionUI(for: projection))
}
```

第二个测试不是在测 registry 本身，而是在锁定“会话执行 UI 只认 projection”这个契约，避免迁移 session list 时又把旧状态源接回来。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature2-task2 -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL or compile error because `WorkbenchShellView` still injects a registry and `SessionListView` still reads `workspaceState.executionRegistry.projection(for:)`.

**Step 3: Write minimal implementation**

完成 consumer 迁移：

- `WorkbenchShellView.configureOnAppear()` 改成 `workspaceState.bindExecutionProjectionStore(claudeService.executionProjectionStore)` 或等价调用，不再创建 `SessionExecutionRegistry`。
- `SessionListView` 把 `projection:` 参数改为读取 `workspaceState.executionProjection(for: item.session.sessionId)`，或者读取一个明确只读的 projection facade。
- 如果 `WorkspaceState.bindExecutionProjectionStore(_:)` 需要在绑定时补一次当前 `selectedSession` 的 foreground state，就在这个方法里做，而不是在 shell 里手动补同步。
- 审计 `ChatView`、`QuickOpenProvider`、`CommandPaletteViewModel`：确认它们不需要 `executionRegistry`，不要为了“统一入口”额外制造耦合。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command again.

Expected: PASS, 且工程编译中不再存在 `workspaceState.executionRegistry` 的生产代码引用。

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchShellView.swift agentGui/Views/SessionListView.swift agentGui/Utilities/WorkspaceState.swift agentGuiTests/WorkspaceStateTests.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift
git commit -m "refactor: migrate session execution ui off registry"
```

### Task 3: 删除 legacy controller/registry 类型和对应测试

**Files:**
- Delete: `agentGui/Services/Execution/SessionExecutionRegistry.swift`
- Delete: `agentGui/Services/Execution/SessionExecutionController.swift`
- Delete: `agentGuiTests/SessionExecutionRegistryTests.swift`
- Delete: `agentGuiTests/SessionExecutionControllerTests.swift`
- Modify: `agentGui.xcodeproj/project.pbxproj`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`

**Step 1: Write the failing test**

把回归焦点从“registry 能同步 store”改成“没有 registry 也能正确工作”：

```swift
@Test
func presentationChangedEventKeepsStoreAsOnlySourceOfTruth() {
    let store = ExecutionProjectionStore()

    store.apply(.started(
        sessionID: "session-a",
        jobID: UUID(),
        providerReference: .builtIn
    ))
    store.apply(.presentationChanged(sessionID: "session-a", state: .background))

    let projection = store.projection(for: "session-a")
    #expect(projection.presentationState == .background)
    #expect(projection.activityState == .running)
}
```

同时把任何仍然依赖 `SessionExecutionRegistryTests` / `SessionExecutionControllerTests` 的断言搬到 store 或 runtime coordinator tests 里，确保删除文件后回归面仍然被锁住。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature2-task3 -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until the legacy assertions are moved and the project no longer requires the deleted registry/controller files.

**Step 3: Write minimal implementation**

执行删除与工程清理：

- 删除 `SessionExecutionRegistry.swift` 与 `SessionExecutionController.swift`。
- 删除对应测试文件。
- 更新 `agentGui.xcodeproj/project.pbxproj`，移除源码和测试文件引用、build phase 条目、group children。
- 将原本依赖 registry/controller 的剩余断言迁移到 `ExecutionProjectionStoreTests`、`WorkspaceStateTests`、`ConversationExecutionRuntimeCoordinatorTests` 中。
- 再做一次 `rg` 审计，确认 `agentGui` 与 `agentGuiTests` 不再引用 `executionRegistry` / `SessionExecutionRegistry` / `SessionExecutionController`。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command again, then run:

```bash
rg -n 'executionRegistry|SessionExecutionRegistry|SessionExecutionController' agentGui agentGuiTests agentGui.xcodeproj/project.pbxproj
```

Expected:

- focused tests PASS
- `rg` 在 `agentGui`、`agentGuiTests`、`agentGui.xcodeproj/project.pbxproj` 中返回 0 条匹配

**Step 5: Commit**

```bash
git add agentGui.xcodeproj/project.pbxproj agentGui/Utilities/WorkspaceState.swift agentGui/Views/Workbench/WorkbenchShellView.swift agentGui/Views/SessionListView.swift agentGuiTests/WorkspaceStateTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift
git rm agentGui/Services/Execution/SessionExecutionRegistry.swift agentGui/Services/Execution/SessionExecutionController.swift agentGuiTests/SessionExecutionRegistryTests.swift agentGuiTests/SessionExecutionControllerTests.swift
git commit -m "refactor: remove legacy session execution registry"
```

### Task 4: 做 focused regression 并锁定“无 registry”验收门槛

**Files:**
- Modify: `docs/plans/2026-03-29-session-execution-registry-removal-implementation-plan.md`
- Modify: `agentGuiTests/WorkspaceStateTests.swift`
- Modify: `agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift`

**Step 1: Write the failing test / guard**

把最终验收门槛显式化，至少保证以下断言已经存在并且在 focused regression 中被执行：

- `WorkspaceState` 在无 registry 条件下仍能发布 foreground/background presentation。
- `ExecutionProjectionStore` 的 `presentationChanged` 不会破坏 running/queued 语义。
- `ConversationExecutionRuntimeCoordinator` 读取 projection store 时，不依赖 registry/controller 的补同步才能看到最新 presentation state。

如果 `ConversationExecutionRuntimeCoordinatorTests` 还存在需要共享 registry fixture 才能成立的测试，就在本任务中改成直接共享同一个 `ExecutionProjectionStore`。

**Step 2: Run regression to verify it fails before final cleanup lands**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature2-final -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until all remaining registry-era assumptions are removed.

**Step 3: Write minimal implementation**

- 清理残余测试中的 registry-era 命名、注释和 fixture。
- 如果某个测试只是为了覆盖 controller cache 同步行为，直接删除；Feature 2 不再保留这类兼容性回归。
- 如有必要，在 `ExecutionProjectionStore` 增补一个小型 helper（例如批量 foreground 更新）来降低 `WorkspaceState` 里的样板代码，但不要引入新的 state cache 对象。

**Step 4: Run regression to verify it passes**

Run the same `xcodebuild` command again, then run:

```bash
rg -n 'executionRegistry|SessionExecutionRegistry|SessionExecutionController' agentGui agentGuiTests agentGui.xcodeproj/project.pbxproj
```

Expected:

- focused regression PASS
- `rg` 结果为 0
- requirements 中的 3 条验收标准全部满足

**Step 5: Commit**

```bash
git add agentGuiTests/WorkspaceStateTests.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionRuntimeCoordinatorTests.swift docs/plans/2026-03-29-session-execution-registry-removal-implementation-plan.md
git commit -m "test: lock no-registry execution projection regression"
```

## 6. Final Verification Checklist

在宣布 Feature 2 完成前，逐项确认：

1. `WorkspaceState`、`WorkbenchShellView`、`SessionListView` 中已无 `executionRegistry` 引用。
2. `SessionExecutionRegistry.swift`、`SessionExecutionController.swift`、对应测试文件都已删除，并从 `project.pbxproj` 移除。
3. `agentGui`、`agentGuiTests`、`agentGui.xcodeproj/project.pbxproj` 中 `rg -n 'executionRegistry|SessionExecutionRegistry|SessionExecutionController'` 返回 0。
4. Focused tests 通过：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature2-final -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/ExecutionProjectionStoreTests -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests CODE_SIGNING_ALLOWED=NO
```

5. 命令面板 consumer audit 结论仍成立：`AppCommandContext` / `QuickOpenProvider` / `CommandPaletteViewModel` 不需要 execution registry 改造。

## 7. Risks And Review Notes

- 最大风险不是删除文件本身，而是遗漏 `project.pbxproj` 清理，导致 CI 或本地 test bundle 继续引用已删文件。
- 第二个风险是把 registry 去掉后，又在 `WorkspaceState` 新增一个自建 projection cache；这会把兼容层换个名字保留下来，违背 Feature 2 目标。
- `selectedSession` 的 foreground 更新只应作用于 store 已知 session；不要因为本轮删除 registry 而重新引入“空 projection 预注册”。
- `ChatView` 已经走 direct-store 路径，Feature 2 不要顺手改它的状态来源；否则会把“删兼容层”扩成“统一所有 UI 入口”的无关重构。
- 实现完成后，review 时重点看 3 件事：是否彻底删除 app-layer registry，是否保留了单一 projection truth，是否把旧回归测试正确迁移成 no-registry 断言。

Plan complete and saved to `docs/plans/2026-03-29-session-execution-registry-removal-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?