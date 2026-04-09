# CL-A1: Auto Diff on Selection 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 点击 Git 变更列表中的任意文件行，立即在工作台右侧触发 Diff 预览；移除独立"查看 Diff"按钮；选中行高亮；支持键盘 ↑↓ 切换文件。

**Architecture:**
在 `GitSidebarViewModel` 上暴露 `selectChange(_:workspaceState:)` 方法，内部代理给已有的 `GitPanelViewModel.selectDiff(for:staged:workspaceState:)`，选中状态通过 `panelViewModel.selectedChange` 反映，无新增冗余状态。`GitSidebarChangesSection` 把行点击绑定到该方法，并用 `.background` + `.focusable()` 实现高亮与键盘导航。

**Tech Stack:** Swift 6.0, SwiftUI (macOS), XCTest, `@Observable`, `@MainActor`

**参考基准：** IDEA 社区版 `git4idea/index/ui/GitStagePanel.kt` — 选中节点直接触发 `GitStageDiffRequestProcessor.updateRequest()`；`GitStageTree.kt` 中 `tree.selectionModel.addListSelectionListener` 立即刷新 diff 区域；无额外按钮。

---

## 现有代码速查

| 文件 | 关键符号 |
|---|---|
| `agentGui/ViewModels/GitSidebarViewModel.swift` | `panelViewModel: GitPanelViewModel`、`filteredStagedChanges` 等 |
| `agentGui/ViewModels/GitPanelViewModel.swift` | `selectedChange: GitFileChange?`、`selectDiff(for:staged:workspaceState:)` |
| `agentGui/Views/Git/GitSidebarChangesSection.swift` | `changeGroup()`、`changeRow()` — 当前含独立"查看 Diff"按钮 |
| `agentGui/Models/GitRepositorySnapshot.swift` | `GitFileChange`（`id = relativePath + status + section`）、`GitChangeSection` |
| `agentGuiTests/GitPanelViewModelHistoryTests.swift` | `StubGitService` 模式参考 — `@MainActor private final class` |

---

## Task 1：GitSidebarViewModel — 选中接口 + 单元测试

**Files:**
- Modify: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Create: `agentGuiTests/GitSidebarViewModelSelectionTests.swift`

---

### Step 1.1 — 写失败测试

在 `agentGuiTests/GitSidebarViewModelSelectionTests.swift` 新建文件，内容如下：

```swift
import XCTest
@testable import agentGui

// MARK: - Spy GitServicing

@MainActor
private final class SpyGitService: GitServicing {
    var diffCallCount = 0
    var lastDiffStagedArg: Bool?
    var lastDiffChange: GitFileChange?

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            repositoryRoot: workingDirectory,
            repositoryName: "repo",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [], unstagedChanges: [], untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to: String, repositoryRoot: URL) async throws {}
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        diffCallCount += 1
        lastDiffStagedArg = staged
        lastDiffChange = change
        return "--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n hello"
    }
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
}

// MARK: - Helpers

@MainActor
private func makeStagedChange(path: String = "Sources/Foo.swift") -> GitFileChange {
    GitFileChange(
        relativePath: path,
        absoluteURL: URL(fileURLWithPath: "/repo/\(path)"),
        status: .modified,
        section: .staged
    )
}

@MainActor
private func makeUnstagedChange(path: String = "Sources/Bar.swift") -> GitFileChange {
    GitFileChange(
        relativePath: path,
        absoluteURL: URL(fileURLWithPath: "/repo/\(path)"),
        status: .modified,
        section: .modified
    )
}

// MARK: - Tests

@MainActor
final class GitSidebarViewModelSelectionTests: XCTestCase {

    func test_initialSelectedChangeID_isNil() {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        XCTAssertNil(vm.selectedChangeID)
    }

    func test_selectChange_stagedFile_callsDiffWithStagedTrue() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        // 预填 snapshot 让 selectDiff 能找到 repositoryRoot
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(spy.diffCallCount, 1)
        XCTAssertEqual(spy.lastDiffStagedArg, true)
    }

    func test_selectChange_unstagedFile_callsDiffWithStagedFalse() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeUnstagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(spy.lastDiffStagedArg, false)
    }

    func test_selectedChangeID_reflectsPanelViewModelAfterSelect() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(vm.selectedChangeID, change.id)
    }

    func test_selectChange_updatesWorkspaceStateDiffText() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertNotNil(ws.selectedGitDiffText)
        XCTAssertEqual(ws.selectedGitDiffTitle, change.relativePath)
    }
}
```

---

### Step 1.2 — 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a1-task1 \
  -only-testing:agentGuiTests/GitSidebarViewModelSelectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：编译错误 `value of type 'GitSidebarViewModel' has no member 'selectChange'` 以及 `selectedChangeID`。

---

### Step 1.3 — 在 GitSidebarViewModel 增加最小实现

修改 `agentGui/ViewModels/GitSidebarViewModel.swift`，在 `private func filter(...)` 之前插入：

```swift
// MARK: - Selection

/// 当前选中文件 ID，代理自 panelViewModel.selectedChange（单一来源）
var selectedChangeID: String? {
    panelViewModel.selectedChange?.id
}

/// 选中文件行 — 立即触发 diff 加载并更新 WorkspaceState。
/// `staged` 语义由 `change.section` 决定；untracked 文件的 staged=false。
func selectChange(_ change: GitFileChange, workspaceState: WorkspaceState) async {
    await panelViewModel.selectDiff(
        for: change,
        staged: change.section == .staged,
        workspaceState: workspaceState
    )
}
```

---

### Step 1.4 — 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a1-task1 \
  -only-testing:agentGuiTests/GitSidebarViewModelSelectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`Test Suite 'GitSidebarViewModelSelectionTests' passed`，4 test cases。

---

### Step 1.5 — Commit

```bash
git add agentGui/ViewModels/GitSidebarViewModel.swift \
        agentGuiTests/GitSidebarViewModelSelectionTests.swift
git commit -m "feat(cl-a1): add selectChange and selectedChangeID to GitSidebarViewModel"
```

---

## Task 2：GitSidebarChangesSection — 行点击选中 + 高亮 + 键盘导航

**Files:**
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`

> 纯 SwiftUI 视图改动。行为逻辑已由 Task 1 单元测试覆盖，此处不新增测试文件。

---

### Step 2.1 — 移除"查看 Diff"按钮

在 `changeRow(change:primaryActionTitle:primaryAction:secondaryActionTitle:secondaryAction:)` 中，**删除**以下整个 Button 块（行 ~130-140）：

```swift
// 删除此段
Button("查看 Diff") {
    Task {
        await sidebarViewModel.panelViewModel.selectDiff(
            for: change,
            staged: change.section == .staged,
            workspaceState: workspaceState
        )
    }
}
.buttonStyle(.borderless)
```

---

### Step 2.2 — 行改为可点击 + 添加选中高亮

将 `changeRow` 方法返回的 `VStack` 替换为以下结构（保留所有原有 HStack 内容，只在外层包装修饰器）：

```swift
private func changeRow(
    change: GitFileChange,
    primaryActionTitle: String,
    primaryAction: @escaping (GitFileChange) -> Void,
    secondaryActionTitle: String? = nil,
    secondaryAction: ((GitFileChange) -> Void)? = nil
) -> some View {
    let isSelected = sidebarViewModel.selectedChangeID == change.id

    return VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(change.relativePath)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(change.status.rawValue.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
            Button(primaryActionTitle) {
                primaryAction(change)
            }
            .buttonStyle(.borderless)

            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, role: .destructive) {
                    secondaryAction(change)
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(
        isSelected
            ? Color.accentColor.opacity(0.15)
            : Color.clear,
        in: RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())
    .onTapGesture {
        Task {
            await sidebarViewModel.selectChange(change, workspaceState: workspaceState)
        }
    }
}
```

> **注意：** `Button` 内的点击事件冒泡优先级高于 `.onTapGesture`。`primaryAction`（暂存/取消暂存）按钮点击**不会**同时触发 diff，行为与 IDEA `HoverIcon` 中"图标点击执行操作，不影响 diff panel选中"一致。后续 CL-A2 会将操作按钮改为 hover overlay，届可移除此说明。

---

### Step 2.3 — 添加键盘 ↑↓ 导航

在 `GitSidebarChangesSection` struct 内部，**添加**以下两处内容：

**1. 在 struct 顶部添加 `@FocusState`**：

```swift
struct GitSidebarChangesSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    @FocusState private var isListFocused: Bool
```

**2. 在 `allChangesForKeyboard` 计算属性（新增）+ 键盘处理方法（新增）**：

在 `body` 之后、`changeGroup` 之前插入：

```swift
/// 所有变更的统一有序列表（staged → unstaged → untracked），用于键盘 ↑↓ 导航。
private var allChangesForKeyboard: [GitFileChange] {
    sidebarViewModel.filteredStagedChanges
        + sidebarViewModel.filteredUnstagedChanges
        + sidebarViewModel.filteredUntrackedChanges
}

private func moveKeyboardSelection(by delta: Int) {
    let all = allChangesForKeyboard
    guard !all.isEmpty else { return }
    let currentID = sidebarViewModel.selectedChangeID
    let currentIndex = all.firstIndex(where: { $0.id == currentID }) ?? -1
    let nextIndex = max(0, min(all.count - 1, currentIndex + delta))
    let nextChange = all[nextIndex]
    Task {
        await sidebarViewModel.selectChange(nextChange, workspaceState: workspaceState)
    }
}
```

**3. 在 `sectionCard` 返回值上添加 focusable + onKeyPress**：

将 `body` 中最终的 `.confirmationDialog(...)` 修饰符**之后**追加：

```swift
.focusable()
.focused($isListFocused)
.onKeyPress(.upArrow) {
    moveKeyboardSelection(by: -1)
    return .handled
}
.onKeyPress(.downArrow) {
    moveKeyboardSelection(by: 1)
    return .handled
}
```

---

### Step 2.4 — 构建确认无编译错误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-cl-a1-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error:|warning:|BUILD'
```

预期：`BUILD SUCCEEDED`，无 error。

---

### Step 2.5 — 回归测试：Task 1 单元测试仍通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-cl-a1-task1 \
  -only-testing:agentGuiTests/GitSidebarViewModelSelectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`Test Suite 'GitSidebarViewModelSelectionTests' passed`。

---

### Step 2.6 — Commit

```bash
git add agentGui/Views/Git/GitSidebarChangesSection.swift
git commit -m "feat(cl-a1): row tap triggers diff, selection highlight, keyboard up/down nav"
```

---

## Task 3：手动冒烟验证清单

构建并运行 App 后，在 Git 面板执行以下验证：

| # | 操作 | 预期结果 |
|---|---|---|
| 1 | 点击"已暂存"区任意文件行 | 右侧 Diff 预览立即更新，行底色变为 accentColor×0.15 |
| 2 | 点击另一个文件行 | 前一行高亮消失，新行高亮，diff 更新 |
| 3 | 点击"暂存" / "取消暂存"按钮 | 操作执行，**不**自动触发 diff（行为不变） |
| 4 | 点击变更列表区域后按 ↓ | 高亮向下移动一行，diff 更新 |
| 5 | 按 ↑ | 高亮向上移动，到顶后不越界 |
| 6 | 打开 App，没有任何暂存变更时 | 无崩溃，无空指针 |

---

## 边界说明

- **untracked 文件的 staged 参数**：`GitFileChange.section == .untracked` 时 `section != .staged`，故 `selectChange` 传入 `staged: false`，与 `git diff HEAD -- <file>` 行为一致（显示未追踪文件与空之间的对比）。GitService 的 `diff(for:staged:repositoryRoot:)` 应已处理此情况——若无，属于 CL-A1 之外的 bug。
- **reconcileSelection 保留**：`GitPanelViewModel.reconcileSelection` 在 snapshot 刷新后自动修正 `selectedChange`，`selectedChangeID` 计算属性自动反映，**无需额外处理**。
- **多选**：CL-A2+ 范畴，CL-A1 不引入。
