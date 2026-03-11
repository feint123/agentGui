# Workspace Sidebar GitPanel Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将侧栏 GitPanel 收敛为“仓库汇总 + 分支切换”轻量区块，恢复文件树主区域地位，并删除与旧 GitPanel 文件级交互相关的冗余代码。

**Architecture:** 保留现有 `GitService -> GitPanelViewModel -> GitPanelView / WorkspacePanelView` 分层，但把 GitPanel 的职责严格收缩到摘要与分支切换。文件级 diff 继续统一走文件树，因此保留共享的 diff 预览状态；GitPanel 专属的变更列表、提交区、危险动作确认和分组折叠状态从 View 与 ViewModel 中删除。分支切换能力优先落在 `GitService`，再由 `GitPanelViewModel` 暴露给视图。

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`, Swift Testing, existing `WorkspaceState`, existing `GitService` and `GitPanelViewModel`.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 先写失败测试，再写最小实现，再删除冗余代码。
- 不保留“暂时隐藏”的旧 GitPanel 文件级交互；凡是不再服务于新需求的 GitPanel 代码都删除。
- 文件树现有 diff 入口是主路径，本次实现不得把 diff 入口再迁回 GitPanel。
- 分支切换先支持“列出本地分支 + 切换本地分支”，不要扩展到新建、删除、远端分支管理。
- 每个任务完成后都提交一个小而明确的 commit。

## 2. 目标文件清单

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`

### 主要测试文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

### 可能新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitBranchReference.swift`

### 计划删除或重写的文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitPanelUITests.swift`

## 3. 关键设计决定

### 3.1 GitPanel 保留什么

保留：

- 仓库名
- 当前分支
- ahead / behind 摘要
- staged / modified / untracked 数量汇总
- 刷新按钮
- 分支切换入口

移除：

- GitPanel 内变更文件列表
- GitPanel 内 diff 打开入口
- GitPanel 内提交区
- GitPanel 内文件级暂存 / 取消暂存 / 丢弃 / 删除
- GitPanel 内危险操作确认弹窗

### 3.2 文件树继续承担什么

- 文件浏览
- Git 状态装饰
- diff 打开入口
- 现有 `WorkspaceState.selectedGitDiff*` 驱动的编辑区 diff 模式

### 3.3 ViewModel 保留什么，删除什么

保留：

- `snapshot`
- `refresh`
- `selectDiff`
- `selectedChange` / `selectedDiffSection` / `selectedDiffText`
- 与文件树 diff 打开路径直接相关的状态

删除：

- `expandedSections`
- `commitMessage`
- `shouldEmphasizeCommitComposer`
- `canCommit`
- `pendingDangerousAction`
- `requestDiscard` / `requestClean` / `confirmPendingAction`
- 仅为 GitPanel 文件列表和提交区服务的 banner / 交互状态

新增：

- `availableBranches`
- `isSwitchingBranch`
- `branchActionError` 或统一错误出口
- `switchBranch(to:)`

## 4. 任务拆解

### Task 1: 为 GitService 增加分支列表与切换接口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`
- Create or Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitBranchReference.swift`

**Step 1: 写失败测试，固定分支列表与切换命令契约**

在 `GitServiceTests.swift` 中新增以下测试：

- `listBranchesUsesExpectedArguments()`
- `switchBranchUsesExpectedArguments()`
- `switchBranchMapsCommandFailureToUserFacingMessage()`

建议测试代码：

```swift
@Test func listBranchesUsesExpectedArguments() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

    runner.results = [
        .success(.init(stdout: "* main\n  feature/sidebar\n", stderr: "", exitCode: 0))
    ]

    let branches = try await service.listBranches(repositoryRoot: repositoryRoot)

    #expect(branches.map(\.name) == ["main", "feature/sidebar"])
    #expect(branches.first?.isCurrent == true)
    #expect(runner.invocations[0].arguments == ["branch", "--list"])
}
```

```swift
@Test func switchBranchUsesExpectedArguments() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

    runner.results = [
        .success(.init(stdout: "", stderr: "", exitCode: 0))
    ]

    try await service.switchBranch(to: "feature/sidebar", repositoryRoot: repositoryRoot)

    #expect(runner.invocations[0].arguments == ["switch", "feature/sidebar"])
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitServiceTests
```

Expected: FAIL，原因应为 `GitService` 尚无 `listBranches` / `switchBranch` 接口与模型。

**Step 3: 写最小实现**

在 `GitService.swift` 中：

- 给 `GitServicing` 增加：

```swift
func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference]
func switchBranch(to branchName: String, repositoryRoot: URL) async throws
```

- `listBranches` 使用：

```swift
["branch", "--list"]
```

- `switchBranch` 使用：

```swift
["switch", branchName]
```

- 解析 `git branch --list` 输出时，至少支持：

```swift
* main
  feature/sidebar
```

- 最小模型建议：

```swift
struct GitBranchReference: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
}
```

**Step 4: 运行测试确认通过**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitServiceTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/GitService.swift agentGuiTests/GitServiceTests.swift agentGui/Models/GitBranchReference.swift
git commit -m "feat: add git branch switching service"
```

### Task 2: 收缩 GitPanelViewModel，只保留摘要与分支切换所需状态

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: 写失败测试，固定新的 ViewModel 职责边界**

在 `GitPanelViewModelTests.swift` 中新增：

- `refreshAlsoLoadsAvailableBranches()`
- `switchBranchRefreshesSnapshotAndBranches()`
- `switchBranchStoresUserFacingErrorOnFailure()`

同时删除或替换以下已不再符合新需求的测试：

- `refreshKeepsExpandedSections()`
- `canCommitRequiresStagedChangesAndMessage()`
- `commitComposerEmphasisTracksStagedChanges()`
- `requestDiscardOnlyStoresPendingAction()`
- `confirmPendingActionExecutesAndRefreshes()`

建议新增测试代码：

```swift
@Test func refreshAlsoLoadsAvailableBranches() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture(branchName: "main")
    service.branches = [
        .init(name: "main", isCurrent: true),
        .init(name: "feature/sidebar", isCurrent: false)
    ]
    let viewModel = GitPanelViewModel(gitService: service)

    await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))

    #expect(viewModel.availableBranches.map(\.name) == ["main", "feature/sidebar"])
}
```

```swift
@Test func switchBranchRefreshesSnapshotAndBranches() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture(branchName: "main")
    service.branches = [
        .init(name: "main", isCurrent: true),
        .init(name: "feature/sidebar", isCurrent: false)
    ]
    let viewModel = GitPanelViewModel(gitService: service)

    await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))
    service.snapshot = .fixture(branchName: "feature/sidebar")
    service.branches = [
        .init(name: "main", isCurrent: false),
        .init(name: "feature/sidebar", isCurrent: true)
    ]

    await viewModel.switchBranch(to: "feature/sidebar")

    #expect(service.switchedBranches == ["feature/sidebar"])
    #expect(viewModel.snapshot?.branchName == "feature/sidebar")
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: FAIL，原因应为 ViewModel 尚无分支状态与切换接口，且旧测试仍绑定提交区/分组折叠逻辑。

**Step 3: 写最小实现并删除旧状态**

在 `GitPanelViewModel.swift` 中：

- 新增：

```swift
var availableBranches: [GitBranchReference] = []
var isSwitchingBranch = false
var branchActionError: String?
```

- 在 `refresh(for:)` 中追加：

```swift
availableBranches = try await gitService.listBranches(repositoryRoot: repositoryRoot)
```

- 新增：

```swift
func switchBranch(to branchName: String) async {
    ...
}
```

- 删除仅服务旧 GitPanel 的状态与方法：

```swift
expandedSections
commitMessage
transientBanner
pendingDangerousAction
requestDiscard
requestClean
confirmPendingAction
commit
performMutation
shouldEmphasizeCommitComposer
canCommit
```

- 保留 `selectDiff` 与 diff 选择状态，因为文件树仍使用它打开 diff。

**Step 4: 更新测试替身**

在 `FakeGitService` 中补上：

```swift
var branches: [GitBranchReference] = []
var switchedBranches: [String] = []
```

以及：

```swift
func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference]
func switchBranch(to branchName: String, repositoryRoot: URL) async throws
```

**Step 5: 运行测试确认通过**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "refactor: simplify git panel state model"
```

### Task 3: 重写 GitPanelView，改成紧凑摘要卡片 + 分支切换入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 先让旧视图编译失败的部分有测试约束**

本任务不强行新增 SwiftUI 视图测试，但要求先整理出必须删除的视图块：

- `changeSections(_:)`
- `changeSection(...)`
- `changeRow(...)`
- `commitComposer`
- `pendingActionTitle`
- `pendingActionMessage`
- 与 `confirmationDialog` 绑定的旧危险动作 UI

同时保留或新增以下 accessibility identifiers：

- `git.panel`
- `git.summary.repository`
- `git.summary.branch`
- `git.panel.refresh`
- `git.branch.menu`

**Step 2: 写最小实现**

将 `GitPanelView` 收敛为单个紧凑区块，结构建议：

```swift
VStack(alignment: .leading, spacing: 8) {
    header
    if let snapshot {
        summary(snapshot)
        branchSwitcher
    } else if isLoading {
        ProgressView()
    } else {
        emptyState
    }
}
```

其中：

- `header` 只保留标题 + 刷新
- `summary` 显示仓库名、分支、ahead/behind、三个数量 pill
- `branchSwitcher` 使用 `Menu` 或 `Picker`，推荐 `Menu`

示例：

```swift
private func branchSwitcher(_ branches: [GitBranchReference]) -> some View {
    Menu {
        ForEach(branches) { branch in
            Button(branch.name) {
                Task { await gitPanelViewModel.switchBranch(to: branch.name) }
            }
            .disabled(branch.isCurrent || gitPanelViewModel.isSwitchingBranch)
        }
    } label: {
        Label("切换分支", systemImage: "arrow.triangle.branch")
    }
    .accessibilityIdentifier("git.branch.menu")
}
```

在 `WorkspacePanelView.swift` 中，只调整布局权重，不改文件树 diff 逻辑：

- `GitPanelView()` 改成紧凑区块
- `treeContent` 用 `.frame(maxHeight: .infinity)` 明确成为主区域
- 若需要，可给 GitPanel 外层加一个轻量背景或卡片边界，但不要做额外设计扩张

**Step 3: 运行编译与 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/GitPanelViewModelTests \
  -only-testing:agentGuiTests/GitServiceTests
```

Expected: PASS。

**Step 4: Commit**

```bash
git add agentGui/Views/GitPanelView.swift agentGui/Views/WorkspacePanelView.swift
git commit -m "refactor: simplify workspace git panel UI"
```

### Task 4: 删除旧 GitPanel 交互遗留代码与不再对齐的测试

**Files:**
- Modify or Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitPanelUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- Search cleanup across: `/Volumes/T7/文稿/Projects/agentGui/agentGui/**`

**Step 1: 删除与旧 GitPanel 文件级交互绑定的测试与标识**

处理原则：

- 若 `GitPanelUITests.swift` 仅覆盖“GitPanel 打开 diff / staged diff / commit composer”，直接删除该文件
- 若保留文件，则重写为“展示摘要 + 分支菜单存在”的最小测试；不要继续维护已过时的 skipped tests

本计划推荐直接删除：

```bash
rm agentGuiUITests/GitPanelUITests.swift
```

并移除与其专属场景强绑定的 `gitFixtureMode` 特例，除非该参数还被其他测试复用。

**Step 2: 清理过时 accessibility identifiers 与条件分支**

删除以下已失效的 GitPanel 标识与视图代码：

- `git.section.staged`
- `git.section.modified`
- `git.section.untracked`
- `git.commit.message`
- `git.commit.submit`
- `git.panel.change.*`
- `git.panel.commitComposer`

保留文件树与 diff 相关标识，因为它们仍服务主路径。

**Step 3: 运行全量相关测试确认清理后仍成立**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/GitServiceTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests \
  -only-testing:agentGuiTests/GitDiffPresentationTests
```

Expected: PASS。

如仍保留 `GitPanelUITests.swift`，再跑：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiUITests/GitPanelUITests
```

Expected: PASS，且不应再出现 skip 掩盖已废弃交互。

**Step 4: Commit**

```bash
git add agentGui agentGuiTests agentGuiUITests
git commit -m "chore: remove obsolete git panel interactions"
```

## 5. 最终验收清单

- GitPanel 只显示仓库摘要和分支切换入口
- GitPanel 不再展示文件变更列表、提交区和文件级动作
- 文件树仍能正常打开 diff
- 分支列表可加载，切换分支后摘要会刷新
- 旧 GitPanel 专属状态和测试已删除
- 相关单元测试通过，若保留 UI 测试则也通过且不依赖 skip

## 6. 执行建议

建议严格按任务顺序执行：

1. 先补 `GitService` 分支能力
2. 再收缩 `GitPanelViewModel`
3. 再重写 `GitPanelView` 和侧栏布局
4. 最后做遗留代码与测试删除

不要先删视图再补分支接口，否则很容易在半途留下编译断裂和测试空窗。