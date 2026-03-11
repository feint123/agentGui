# Basic Git UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a minimal in-app Git UI for the current workspace that supports repository detection, status summary, file-level change browsing, patch preview, staging/unstaging/discarding, and non-interactive local commit.

**Architecture:** Keep Git UI as a user-facing workspace feature, not an Agent tool. Implement a dedicated `GitService` with a small command-runner abstraction and a parser for `git status --porcelain=v1 --branch`, then expose runtime-only state through a `GitPanelViewModel` shared by `WorkspacePanelView` and `FileEditorView`. Use the existing three-column layout: left sidebar for repository summary and change list, center editor for text file editing or diff preview, and do not persist Git state in SwiftData.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Foundation `Process`, existing `WorkspaceState`, `WorkspacePanelView`, `FileEditorView`, and macOS confirmation/alert patterns already used in the app.

---

## 1. 实施原则

- Git UI 不接入 `ClaudeService` 工具时间线，也不复用 Agent `bash` 工具调用记录作为主链路。
- V1 只支持非交互式 Git 命令，严格对齐需求文档边界。
- 先做纯模型、解析器和 service，再接 ViewModel，最后接 UI。
- 仓库状态保持运行时内存态，不引入 SwiftData 模型。
- 所有危险操作必须显式确认；丢弃改动与删除未跟踪文件不能做隐式执行。
- 测试优先覆盖三段链路：状态解析、Git service 行为、ViewModel 状态流转。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitRepositorySnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitStatusParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitStatusParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`

## 3. 关键架构决策

### 3.1 Git 执行链路

不要让 Git UI 走 `BashSession`。原因：

- Git 状态刷新是频繁、短命、结构化查询，和 Agent 工具执行不是同一个问题。
- `BashSession` 以持久 shell 和 transcript 为中心，更适合工具调用，不适合 UI 轮询和错误分类。
- V1 需要明确区分“非 Git 目录”“状态变更失效”“提交失败”等用户态错误，独立 service 更容易做结构化返回。

建议引入：

```swift
protocol GitCommandRunning {
    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult
}

struct GitCommandResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}
```

`GitService` 依赖该 runner。生产实现使用 `Process`，测试实现使用 fake runner。

### 3.2 UI 状态共享方式

Git 运行时状态由 `GitPanelViewModel` 承载，并从 `MainSplitView` 注入到：

- `WorkspacePanelView`：展示摘要、变更列表、commit 输入框
- `FileEditorView`：切换普通文件视图 / Git diff 视图

`WorkspaceState` 只补最小跨栏状态，例如：

- 当前选中的 Git diff 请求
- 当前编辑区是否处于 Git diff 模式

不要把 Git 业务状态塞进 `WorkspaceState`；它仍主要负责工作区导航状态。

## 4. 任务拆解

### Task 1: 建立 Git 领域模型与 status 解析器

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/GitRepositorySnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitStatusParser.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitStatusParserTests.swift`

**Step 1: 写失败测试，固定 porcelain 解析契约**

新增测试覆盖以下行为：

- 能从 `git status --porcelain=v1 --branch` 解析当前分支名
- 能识别 `ahead/behind` 计数
- 能把 `XY path` 映射为 `staged / modified / untracked` 三类列表
- 能处理重命名行与删除行
- 非 Git 输出或空输出能返回结构化解析错误，而不是崩溃

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct GitStatusParserTests {

    @Test func parsesBranchCountersAndSections() throws {
        let output = """
        ## main...origin/main [ahead 2, behind 1]
         M agentGui/Views/FileEditorView.swift
        M  agentGui/Views/WorkspacePanelView.swift
        ?? docs/spec/2026-03-11-basic-git-ui-requirements.md
        """

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.branchName == "main")
        #expect(snapshot.aheadCount == 2)
        #expect(snapshot.behindCount == 1)
        #expect(snapshot.unstagedChanges.count == 1)
        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.untrackedChanges.count == 1)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitStatusParserTests
```

Expected: FAIL，因为 Git 模型与解析器还不存在。

**Step 3: 写最小实现**

在 `GitRepositorySnapshot.swift` 中新增最小模型：

```swift
enum GitChangeSection: String, Codable, Equatable {
    case staged
    case modified
    case untracked
}

enum GitChangeStatus: String, Codable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { relativePath + ":" + status.rawValue + ":" + section.rawValue }
    let relativePath: String
    let absoluteURL: URL
    let status: GitChangeStatus
    let section: GitChangeSection
}

struct GitRepositorySnapshot: Equatable {
    let repositoryRoot: URL
    let repositoryName: String
    let branchName: String
    let hasRemoteTrackingBranch: Bool
    let aheadCount: Int
    let behindCount: Int
    let stagedChanges: [GitFileChange]
    let unstagedChanges: [GitFileChange]
    let untrackedChanges: [GitFileChange]
}
```

在 `GitStatusParser.swift` 中实现：

- `parseStatus(_:repositoryRoot:)`
- branch line 解析
- `XY` 状态位到 section/status 的映射
- 重命名行中 `old -> new` 只保留新路径作为 UI 主路径

不要在此阶段处理 Git 命令执行；只做纯解析。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/GitRepositorySnapshot.swift agentGui/Services/GitStatusParser.swift agentGuiTests/GitStatusParserTests.swift
git commit -m "feat: add git status models and parser"
```

### Task 2: 建立 GitService 与命令执行抽象

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`

**Step 1: 写失败测试，固定 service 行为边界**

新增测试覆盖：

- `repositorySnapshot(for:)` 在仓库子目录下能返回仓库根与 snapshot
- 非 Git 目录返回可识别错误
- `diff(for:staged:)` 能根据 staged 参数切换 `git diff` / `git diff --cached`
- `stageAll()`、`stage(path:)`、`unstage(path:)`、`discard(path:)`、`cleanUntracked(path:)` 使用正确命令
- `commit(message:)` 对空 message 做本地参数校验，不把空消息发给 Git

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct GitServiceTests {

    @Test func commitRejectsEmptyMessageBeforeRunningGit() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)

        await #expect(throws: GitServiceError.emptyCommitMessage) {
            try await service.commit(message: "   ", repositoryRoot: URL(fileURLWithPath: "/tmp/repo"))
        }

        #expect(runner.invocations.isEmpty)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitServiceTests
```

Expected: FAIL，因为 `GitService` 与 command runner 还不存在。

**Step 3: 写最小实现**

在 `GitService.swift` 中新增：

```swift
enum GitServiceError: LocalizedError, Equatable {
    case notAGitRepository
    case commandFailed(String)
    case parseFailed(String)
    case emptyCommitMessage
    case binaryDiffUnavailable
}

@MainActor
final class GitService {
    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String
    func stage(path: String, repositoryRoot: URL) async throws
    func stageAll(repositoryRoot: URL) async throws
    func unstage(path: String, repositoryRoot: URL) async throws
    func discard(path: String, repositoryRoot: URL) async throws
    func cleanUntracked(path: String, repositoryRoot: URL) async throws
    func commit(message: String, repositoryRoot: URL) async throws
}
```

命令边界严格限定为需求文档中的非交互式命令。

生产 runner 建议实现为 `ProcessGitCommandRunner`：

- 使用 `/usr/bin/env` + `git`
- 在 `workingDirectory` 中执行
- 收集 `stdout` / `stderr` / exit code
- 不尝试注入 shell 拼接字符串，尽量使用 arguments 数组

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/GitService.swift agentGuiTests/GitServiceTests.swift
git commit -m "feat: add git service for non-interactive repository operations"
```

### Task 3: 建立 GitPanelViewModel，统一 sidebar 与 editor 的运行时状态

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: 写失败测试，固定 ViewModel 状态流转**

新增测试覆盖：

- 绑定工作目录后可触发 refresh 并得到 snapshot
- 非 Git 目录时生成空态而不是 error storm
- 选择某个 change 后会写入 editor 所需的 diff 选择状态
- 成功执行 stage/unstage/commit 后自动 refresh
- 危险操作只发出待确认 intent，不直接执行

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct GitPanelViewModelTests {

    @Test func refreshStoresSnapshotAndClearsLoadError() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main")
        let viewModel = GitPanelViewModel(gitService: service)

        await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))

        #expect(viewModel.snapshot?.branchName == "main")
        #expect(viewModel.loadError == nil)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: FAIL，因为 ViewModel 和新的 workspace 状态字段还不存在。

**Step 3: 写最小实现**

在 `GitPanelViewModel.swift` 中新增运行时状态：

```swift
@Observable
@MainActor
final class GitPanelViewModel {
    var snapshot: GitRepositorySnapshot?
    var isLoading = false
    var loadError: String?
    var selectedChange: GitFileChange?
    var selectedDiffIsStaged = false
    var selectedDiffText: String?
    var commitMessage = ""
    var transientBanner: String?
    var pendingDangerousAction: GitDangerousAction?

    func refresh(for workingDirectory: URL) async
    func selectDiff(for change: GitFileChange, staged: Bool, workspaceState: WorkspaceState) async
    func stage(_ change: GitFileChange) async
    func unstage(_ change: GitFileChange) async
    func stageAll() async
    func requestDiscard(_ change: GitFileChange)
    func requestClean(_ change: GitFileChange)
    func confirmPendingAction() async
    func commit() async
}
```

在 `WorkspaceState.swift` 中补最小编辑区联动状态，例如：

```swift
var selectedGitDiffPath: URL?
var selectedGitDiffText: String?
var selectedGitDiffTitle: String?
```

约束：

- `WorkspaceState` 只存“当前编辑区该显示什么”，不存仓库业务状态
- `MainSplitView` 创建单个 `GitPanelViewModel` 实例并注入到左右两栏

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGui/Utilities/WorkspaceState.swift agentGui/Views/MainSplitView.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "feat: add shared git panel view model"
```

### Task 4: 在侧栏接入 Git 摘要、变更列表和 commit composer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`

**Step 1: 写失败测试，先固定 ViewModel 驱动下的 UI 数据分层**

如果当前项目不方便直接做 SwiftUI snapshot test，至少补 ViewModel 层断言，固定以下展示语义：

- 有 snapshot 且有变更时，显示 branch、计数和三个分组
- 非 Git 目录时，Git panel 显示空态
- 无变更时，显示“工作区干净”与可折叠 commit 区域

若需要，可先补一个极小 presentation helper 而不是直接测试 View 树。

**Step 2: 运行测试确认失败**

Run 同 Task 3 的 focused tests。

Expected: FAIL，因为 Git panel UI 还未接入主界面。

**Step 3: 写最小实现**

新增 `GitPanelView.swift`，拆成以下小块：

- `repositorySummarySection`
- `changeCountsRow`
- `changeListSection(title:changes:staged:)`
- `commitComposerSection`
- `nonRepositoryEmptyState`

在 `WorkspacePanelView.swift` 中：

- 目录栏下方插入 `GitPanelView`
- `onAppear` 和工作目录切换时触发 `gitViewModel.refresh`
- 文件树前保留 todo 区块顺序，不要改乱现有布局

要求：

- Git 摘要区要明显但不能压过文件树
- commit 输入只在当前目录是 Git 仓库时显示
- 加入“刷新”按钮，但避免把按钮堆进顶部目录栏

**Step 4: 再跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/GitPanelView.swift agentGui/Views/WorkspacePanelView.swift agentGui/Utilities/WorkspaceState.swift
git commit -m "feat: add git sidebar panel"
```

### Task 5: 在编辑区接入 Git diff 预览模式

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`

**Step 1: 写失败测试，固定编辑区模式切换规则**

新增测试或最小 presentation 断言，覆盖：

- 普通文件点击仍走现有文本 / 图片 / PDF 编辑逻辑
- 从 Git panel 选择 diff 后，编辑区进入 diff 预览模式
- 退出 diff 后能回到普通文件显示
- diff 文本为空或二进制不可显示时，给出明确空态

如果难以直接测试 SwiftUI 视图，优先抽一个最小的 `FileEditorDisplayMode` 帮助枚举并做单测。

**Step 2: 运行测试确认失败**

Run 相关 focused tests。

Expected: FAIL，因为编辑器目前只支持文件内容，不支持 diff 视图。

**Step 3: 写最小实现**

新增 `GitDiffView.swift`，首版只做补丁文本视图：

```swift
struct GitDiffView: View {
    let title: String
    let diffText: String
}
```

在 `FileEditorView.swift` 中新增模式分支：

- 若 `workspaceState.selectedGitDiffText != nil`，优先显示 `GitDiffView`
- 文件树点击普通文件时清空 diff 模式
- Git panel 选择 diff 时，不要破坏现有 `selectedFile` 逻辑，可同时保留文件 URL 供后续跳回原文件

要求：

- diff header 中显示路径、是否 staged、返回文件按钮
- 不要在首版实现富文本 hunk 高亮
- 保留现有错误弹窗模式

**Step 4: 再跑 focused tests**

Run relevant tests。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/GitDiffView.swift agentGui/Views/FileEditorView.swift agentGui/Utilities/WorkspaceState.swift
git commit -m "feat: add git diff preview mode to file editor"
```

### Task 6: 在文件树行上接入 Git 状态装饰与基础操作入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`

**Step 1: 写失败测试，固定文件状态装饰映射**

优先补纯函数或 presentation 测试，覆盖：

- 已变更文件能根据 `relativePath` 匹配到状态 badge
- 未变更文件不显示 badge
- `Modified`、`Added`、`Deleted`、`Untracked` 显示稳定缩写或颜色语义

**Step 2: 运行测试确认失败**

Run focused tests。

Expected: FAIL，因为文件树尚无 Git 状态装饰。

**Step 3: 写最小实现**

在 `WorkspacePanelView.swift` 的 `FileRowView` 中补轻量 badge：

- 根据 `GitPanelViewModel.snapshot` 生成相对路径到状态的索引
- 文件项右侧显示单字符或短字符状态，例如 `M`、`A`、`D`、`?`
- 右键菜单或 hover 操作加入：查看 diff、暂存、取消暂存、丢弃改动

约束：

- 目录项不显示 Git badge
- 危险操作仍走 ViewModel 的 confirm 流程
- 不引入复杂上下文菜单嵌套

**Step 4: 再跑 focused tests**

Run relevant tests。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/WorkspacePanelView.swift agentGui/Views/GitPanelView.swift agentGui/ViewModels/GitPanelViewModel.swift
git commit -m "feat: add git decorations and file actions"
```

### Task 7: 接入危险操作确认、错误反馈和回归测试

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: 增加回归测试，固定确认与错误分类语义**

补以下测试：

- `requestDiscard` 仅设置待确认状态，不立即执行 Git
- `confirmPendingAction` 成功后清除 pending state 并刷新 snapshot
- `notAGitRepository` 会落到 non-repo 空态，不弹致命错误
- commit 失败时保留用户输入的 message，不自动清空

**Step 2: 运行 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/GitStatusParserTests \
  -only-testing:agentGuiTests/GitServiceTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: PASS。

**Step 3: 接入 UI 确认与反馈**

在侧栏或 Git panel 容器视图中：

- 使用 `confirmationDialog` 展示 `丢弃改动` / `删除未跟踪文件` 确认
- 使用轻量 banner 或行内状态文案展示操作成功反馈
- 使用 `.alert` 展示结构化错误信息

要求：

- commit 成功后清空 message 并刷新状态
- commit 失败不清空 message
- refresh 期间禁用重复点击按钮

**Step 4: 跑更广一点的回归检查**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/GitStatusParserTests \
  -only-testing:agentGuiTests/GitServiceTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests \
  -only-testing:agentGuiTests/TextEditorViewRangeSafetyTests
```

Expected: PASS，确认 `FileEditorView` 的新 diff 模式没有干扰现有编辑器基础安全测试。

**Step 5: Commit**

```bash
git add agentGui/Views/WorkspacePanelView.swift agentGui/Views/GitPanelView.swift agentGui/ViewModels/GitPanelViewModel.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "feat: finalize git ui confirmations and feedback"
```

## 5. 关键实现细节

### 5.1 为什么单独做 GitService，而不是直接套 BashSession

因为 Git UI 的核心问题不是“执行命令”，而是“稳定地读取结构化仓库状态并把错误映射成用户可理解的 UI 语义”。`BashSession` 以持久 shell transcript 为中心，适合 Agent 工具；Git UI 需要的是短命命令、可测试参数数组、明确 exit code 和无工具时间线副作用的用户态 service。

### 5.2 为什么 Git 状态不落 SwiftData

仓库状态本质上是工作区运行时快照，而不是应用业务数据。把 `stagedChanges`、`branchName` 之类内容持久化到 SwiftData 只会引入陈旧数据、同步问题和不必要的迁移成本。V1 用 ViewModel 持有快照已经足够。

### 5.3 为什么 diff 模式放到 FileEditorView，而不是新开第四栏

当前产品的核心布局已经是三栏。Git V1 的目标是补足最常用闭环，而不是重做信息架构。把 diff 预览接入中间编辑区可以最小化导航成本，也能复用已有“左侧选中，中央展示”的心智模型。

## 6. 风险与回退策略

- 如果 `git status --porcelain=v1 --branch` 对重命名或特殊路径场景解析复杂度超出预期，V1 先以 `M/A/D/?` 主路径为准，重命名支持可以降级为普通修改展示，但不要阻塞主链路。
- 如果文件树行内右键菜单实现成本偏高，可先上 Git panel 内操作按钮，文件树 badge 与右键菜单延后为第二小步，不影响主闭环。
- 如果 `FileEditorView` 接入 diff 模式后状态切换过于复杂，可先把 diff 预览做成独立 `sheet`，但只有在编辑区复用明显阻塞实现时才降级。

## 7. 完成定义

满足以下条件即可视为 V1 完成：

1. 当前工作目录位于 Git 仓库时，侧栏能显示仓库摘要与变更列表。
2. 用户可从 UI 查看已修改文件的 diff。
3. 用户可完成暂存、取消暂存、全部暂存。
4. 用户可在确认后丢弃改动或删除未跟踪文件。
5. 用户可输入 commit message 并完成一次本地非交互式 commit。
6. 非 Git 目录、空工作区、commit 失败、diff 不可显示等情况都有明确空态或错误反馈。
7. `GitStatusParserTests`、`GitServiceTests`、`GitPanelViewModelTests` 至少全部通过。

Plan complete and saved to `docs/plans/2026-03-11-basic-git-ui-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?