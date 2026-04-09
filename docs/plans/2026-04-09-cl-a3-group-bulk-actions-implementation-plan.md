# CL-A3: 组级批量暂存 / 取消暂存 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在已暂存 / 未暂存 / 未跟踪三个变更组的分组标题行右侧各增加一个批量操作按钮（"全部暂存" / "全部取消暂存"），触发 `git add -A` 或 `git restore --staged .` 完成整组的一键批量操作。

**Architecture:**
1. `GitServicing` 协议新增 `stageAll(repositoryRoot:)` / `unstageAll(repositoryRoot:)` 两个方法；
2. `GitService` 用现有 `runMutation(...)` 私有助手实现两个命令；
3. `GitPanelViewModel` 按现有 `mutate(...)` 模式新增 `stageAll(workspaceState:)` / `unstageAll(workspaceState:)` 包装方法；
4. `GitSidebarChangesSection.changeGroup()` 增加两个可选参数 `bulkActionTitle: String?` / `bulkAction: (() -> Void)?`，分组 header 渲染为 `HStack`（左侧 title，右侧 bulk button）。
整个改动**不触碰 diff 预览、selectedChange、filteredChanges 逻辑**，每层独立可测。

**Tech Stack:** Swift 6.0, SwiftUI (macOS), XCTest, `@MainActor`

**参考来源：** IDEA 社区版 `git4idea/index/ui/`
- `GitStageAllAction`（`Git.Stage.Toolbar` group）→ `GitAddOperation.stage(changes: allChanges, repo)` ≈ `git add -A`
- `GitResetAllAction`（`Git.Stage.Toolbar` group）→ `GitResetOperation.reset(changes: allStaged, repo)` ≈ `git restore --staged .`
- 两个 Action 注册在 Toolbar ActionGroup 中，始终可见；agentGui 版本改为分组 header 行内 button（macOS 风格更紧凑）

---

## 现有代码速查

| 文件 | 关键符号 |
|---|---|
| `agentGui/Services/GitService.swift` | `GitServicing` 协议 (L1–L25)、`runMutation(_:repositoryRoot:)` 私有助手、已有 `stage` / `unstage` 实现 |
| `agentGui/ViewModels/GitPanelViewModel.swift` | `mutate(_:action:workspaceState:)` 私有助手 (L200–L215)、`stage(change:workspaceState:)` 包装模式 (L99–L103) |
| `agentGui/ViewModels/GitSidebarViewModel.swift` | `filteredStagedChanges` / `filteredUnstagedChanges` / `filteredUntrackedChanges` |
| `agentGui/Views/Git/GitSidebarChangesSection.swift` | `changeGroup(title:changes:primaryActionTitle:primaryAction:secondaryActionTitle:secondaryAction:)` (L120+)、三处调用位于 `body` |
| `agentGuiTests/GitSidebarViewModelSelectionTests.swift` | `SpyGitService` — 协议 stub，**需同步更新** |
| `agentGuiTests/GitPanelViewModelHistoryTests.swift` | `StubGitService` — 协议 stub，**需同步更新** |

---

## Task 1：Service 层 — 协议 + 实现 + 现有 Stub 同步

**Files:**
- Modify: `agentGui/Services/GitService.swift`
- Modify: `agentGuiTests/GitSidebarViewModelSelectionTests.swift` (SpyGitService stub 同步)
- Modify: `agentGuiTests/GitPanelViewModelHistoryTests.swift` (StubGitService stub 同步)
- Create: `agentGuiTests/GitPanelViewModelBulkStageTests.swift`

---

### Step 1.1 — 新建测试文件，写失败测试

创建 `agentGuiTests/GitPanelViewModelBulkStageTests.swift`，内容如下：

```swift
import XCTest
@testable import agentGui

// MARK: - Spy

@MainActor
private final class BulkStageSpyGitService: GitServicing {
    var stageAllCallCount = 0
    var unstageAllCallCount = 0
    var snapshotToReturn: GitRepositorySnapshot?

    private func defaultRoot() -> URL { URL(fileURLWithPath: "/repo") }

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        snapshotToReturn ?? GitRepositorySnapshot(
            repositoryRoot: defaultRoot(),
            repositoryName: "repo",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [], unstagedChanges: [], untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to: String, repositoryRoot: URL) async throws {}
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String { "" }
    func stage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func unstage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func discard(change: GitFileChange, repositoryRoot: URL) async throws {}
    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {}
    func fetch(repositoryRoot: URL) async throws {}
    func pull(repositoryRoot: URL) async throws {}
    func push(repositoryRoot: URL) async throws {}
    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {}
    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] { [] }
    func saveStash(message: String?, repositoryRoot: URL) async throws {}
    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {}
    func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] { [] }
    // — 新增方法 (Step 1.1 时尚不存在，触发编译报错) —
    func stageAll(repositoryRoot: URL) async throws { stageAllCallCount += 1 }
    func unstageAll(repositoryRoot: URL) async throws { unstageAllCallCount += 1 }
}

// MARK: - GitPanelViewModel bulk stage tests

@MainActor
final class GitPanelViewModelBulkStageTests: XCTestCase {

    func test_stageAll_callsServiceStageAll() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.stageAll()

        XCTAssertEqual(spy.stageAllCallCount, 1)
    }

    func test_unstageAll_callsServiceUnstageAll() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.unstageAll()

        XCTAssertEqual(spy.unstageAllCallCount, 1)
    }

    func test_stageAll_triggersRefreshAfterOperation() async {
        let spy = BulkStageSpyGitService()
        // snapshot with staged change to verify refresh happened
        spy.snapshotToReturn = GitRepositorySnapshot(
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            repositoryName: "repo",
            branchName: "feat",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [],
            unstagedChanges: [],
            untrackedChanges: []
        )
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.stageAll()

        // snapshot should be set after the refresh that follows stageAll
        XCTAssertNotNil(vm.snapshot)
        XCTAssertEqual(vm.snapshot?.branchName, "feat")
    }

    func test_stageAll_serviceFailure_capturesBranchActionError() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        spy.stageAllShouldThrow = true   // 下面 Step 1.2 起生效

        await vm.stageAll()

        XCTAssertNotNil(vm.branchActionError)
    }

    func test_unstageAll_noRepositoryRoot_doesNothing() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        // currentWorkingDirectory 和 snapshot 均为 nil

        await vm.unstageAll()

        XCTAssertEqual(spy.unstageAllCallCount, 0)
    }
}
```

> 预期：编译报错 —  
> `value of type 'BulkStageSpyGitService' has no member 'stageAll'`（协议尚无该方法）  
> `value of type 'GitPanelViewModel' has no member 'stageAll'`（ViewModel 尚无该方法）  
> `value of type 'BulkStageSpyGitService' has no member 'stageAllShouldThrow'`（Step 1.2 之前）

---

### Step 1.2 — 向 `GitServicing` 协议和 `GitService` 添加两个方法

**修改** `agentGui/Services/GitService.swift`：

1. 在 `GitServicing` 协议（`@MainActor protocol GitServicing`）中追加：

```swift
    func stageAll(repositoryRoot: URL) async throws
    func unstageAll(repositoryRoot: URL) async throws
```

2. 在 `GitService` 实现中追加（紧跟 `unstage` 方法后）：

```swift
    func stageAll(repositoryRoot: URL) async throws {
        try await runMutation(["add", "-A"], repositoryRoot: repositoryRoot)
    }

    func unstageAll(repositoryRoot: URL) async throws {
        try await runMutation(["restore", "--staged", "."], repositoryRoot: repositoryRoot)
    }
```

---

### Step 1.3 — 补全 Spy 中的 `stageAllShouldThrow` 支持

在 `GitPanelViewModelBulkStageTests.swift` 的 `BulkStageSpyGitService` 中：

1. 添加属性：

```swift
    var stageAllShouldThrow = false
```

2. 修改 `stageAll` 实现：

```swift
    func stageAll(repositoryRoot: URL) async throws {
        if stageAllShouldThrow { throw GitServiceError.commandFailed("stub error") }
        stageAllCallCount += 1
    }
```

---

### Step 1.4 — 同步更新现有协议 Stub

**修改** `agentGuiTests/GitSidebarViewModelSelectionTests.swift` 内 `SpyGitService`，在末尾 `listCommits` 方法后追加：

```swift
    func stageAll(repositoryRoot: URL) async throws {}
    func unstageAll(repositoryRoot: URL) async throws {}
```

**修改** `agentGuiTests/GitPanelViewModelHistoryTests.swift` 内 `StubGitService`，在末尾 `listCommits` 方法后追加：

```swift
    func stageAll(repositoryRoot: URL) async throws {}
    func unstageAll(repositoryRoot: URL) async throws {}
```

---

### Step 1.5 — 运行 Task 1 专项（Service 层）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a3-task1 \
  -only-testing:agentGuiTests/GitPanelViewModelBulkStageTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|PASSED|FAILED|Test suite"
```

预期：`Test Suite 'GitPanelViewModelBulkStageTests' passed`（除 `serviceFailure` 测试外，该测试此时因 ViewModel 还没实现而 FAIL — Task 2 再补）

> **注：** `test_stageAll_serviceFailure_capturesBranchActionError` 和 `test_stageAll_triggersRefreshAfterOperation` 以及 `test_stageAll_callsServiceStageAll` 将在 Task 2 完成后统一通过，Step 1.5 只确认编译通过 + 无协议编译错误。

---

## Task 2：ViewModel 层 — `GitPanelViewModel` 包装方法

**Files:**
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`

---

### Step 2.1 — 在 `GitPanelViewModel` 中实现 `stageAll` / `unstageAll`

紧跟 `unstage(change:workspaceState:)` 方法后追加两个方法（不破坏现有方法顺序）：

```swift
    func stageAll(workspaceState: WorkspaceState? = nil) async {
        await mutate("正在全部暂存", action: { repositoryRoot in
            try await gitService.stageAll(repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func unstageAll(workspaceState: WorkspaceState? = nil) async {
        await mutate("正在全部取消暂存", action: { repositoryRoot in
            try await gitService.unstageAll(repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }
```

---

### Step 2.2 — 运行 Task 2 专项（ViewModel 层）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a3-task2 \
  -only-testing:agentGuiTests/GitPanelViewModelBulkStageTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|PASSED|FAILED|Test suite"
```

预期：`Test Suite 'GitPanelViewModelBulkStageTests' passed`（全部 5 个测试绿）

---

## Task 3：View 层 — 分组 Header 批量操作按钮

**Files:**
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`

---

### Step 3.1 — 更新 `changeGroup` 函数签名（增加可选 bulk 参数）

`changeGroup` 当前签名：

```swift
private func changeGroup(
    title: String,
    changes: [GitFileChange],
    primaryActionTitle: String,
    primaryAction: @escaping (GitFileChange) -> Void,
    secondaryActionTitle: String? = nil,
    secondaryAction: ((GitFileChange) -> Void)? = nil
) -> some View {
```

修改后签名（追加两个带默认值的可选参数）：

```swift
private func changeGroup(
    title: String,
    changes: [GitFileChange],
    primaryActionTitle: String,
    primaryAction: @escaping (GitFileChange) -> Void,
    secondaryActionTitle: String? = nil,
    secondaryAction: ((GitFileChange) -> Void)? = nil,
    bulkActionTitle: String? = nil,
    bulkAction: (() -> Void)? = nil
) -> some View {
```

---

### Step 3.2 — 修改分组 header 渲染逻辑

在 `changeGroup` 函数体的 `VStack` 顶部，将原来的 `Text(title)` 替换为带 bulk button 的 `HStack`：

**原代码：**

```swift
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        ForEach(changes) { change in
```

**替换为：**

```swift
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let bulkActionTitle, let bulkAction {
                Button(bulkActionTitle, action: bulkAction)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(changes) { change in
```

---

### Step 3.3 — 更新三处 `changeGroup` 调用位置，传入 bulk 参数

在 `body` 中找到三处现有的 `changeGroup(...)` 调用，各自补充 `bulkActionTitle` + `bulkAction`：

**"已暂存" 组：**

```swift
changeGroup(
    title: "已暂存",
    changes: sidebarViewModel.filteredStagedChanges,
    primaryActionTitle: "取消暂存",
    primaryAction: { change in
        Task { await sidebarViewModel.panelViewModel.unstage(change: change, workspaceState: workspaceState) }
    },
    bulkActionTitle: "全部取消暂存",
    bulkAction: {
        Task { await sidebarViewModel.panelViewModel.unstageAll(workspaceState: workspaceState) }
    }
)
```

**"未暂存" 组：**

```swift
changeGroup(
    title: "未暂存",
    changes: sidebarViewModel.filteredUnstagedChanges,
    primaryActionTitle: "暂存",
    primaryAction: { change in
        Task { await sidebarViewModel.panelViewModel.stage(change: change, workspaceState: workspaceState) }
    },
    secondaryActionTitle: "丢弃",
    secondaryAction: { change in
        sidebarViewModel.requestDiscard(change)
    },
    bulkActionTitle: "全部暂存",
    bulkAction: {
        Task { await sidebarViewModel.panelViewModel.stageAll(workspaceState: workspaceState) }
    }
)
```

**"未跟踪" 组：**

```swift
changeGroup(
    title: "未跟踪",
    changes: sidebarViewModel.filteredUntrackedChanges,
    primaryActionTitle: "暂存",
    primaryAction: { change in
        Task { await sidebarViewModel.panelViewModel.stage(change: change, workspaceState: workspaceState) }
    },
    bulkActionTitle: "全部暂存",
    bulkAction: {
        Task { await sidebarViewModel.panelViewModel.stageAll(workspaceState: workspaceState) }
    }
)
```

---

### Step 3.4 — 构建验证（完整编译）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-cl-a3-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

预期：`BUILD SUCCEEDED`，无新增 warning。

---

## Task 4：回归验证

运行与 Git 面板相关的全部测试（CL-A1 / CL-A2 / CL-A3 + 历史测试）：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a3-regression \
  -only-testing:agentGuiTests/GitPanelViewModelBulkStageTests \
  -only-testing:agentGuiTests/GitSidebarViewModelSelectionTests \
  -only-testing:agentGuiTests/GitPanelViewModelHistoryTests \
  -only-testing:agentGuiTests/GitChangeBadgeDisplayTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|PASSED|FAILED|Test suite"
```

预期：所有测试 PASSED。

---

## 变更文件总览

| 文件 | 变更类型 | 内容摘要 |
|---|---|---|
| `agentGui/Services/GitService.swift` | Modify | 协议增加 `stageAll` / `unstageAll`；`GitService` 实现两个命令 |
| `agentGui/ViewModels/GitPanelViewModel.swift` | Modify | 新增 `stageAll(workspaceState:)` / `unstageAll(workspaceState:)`，复用 `mutate` 模式 |
| `agentGui/Views/Git/GitSidebarChangesSection.swift` | Modify | `changeGroup` 增加 `bulkActionTitle` / `bulkAction` 参数；header 改为 `HStack`；三处调用更新 |
| `agentGuiTests/GitPanelViewModelBulkStageTests.swift` | Create | 5 个单元测试 —  `stageAll` / `unstageAll` 调用验证 + 刷新 + 错误捕获 + 无 root 防卫 |
| `agentGuiTests/GitSidebarViewModelSelectionTests.swift` | Modify | `SpyGitService` 同步追加 `stageAll` / `unstageAll` stub |
| `agentGuiTests/GitPanelViewModelHistoryTests.swift` | Modify | `StubGitService` 同步追加 `stageAll` / `unstageAll` stub |

---

## 验收标准

- [ ] `git add -A` 在"未暂存"和"未跟踪"组的"全部暂存"按钮点击后被调用
- [ ] `git restore --staged .` 在"已暂存"组的"全部取消暂存"按钮点击后被调用
- [ ] 操作完成后 snapshot 自动刷新（通过 `mutate` 内置的 `refresh` 调用）
- [ ] Service 层失败时错误被捕获到 `branchActionError`（不崩溃）
- [ ] 无 `currentWorkingDirectory` 和 `snapshot` 时调用无副作用
- [ ] 三个现有协议 stub 编译通过（无 `does not conform to protocol` 报错）
- [ ] 所有回归测试绿
