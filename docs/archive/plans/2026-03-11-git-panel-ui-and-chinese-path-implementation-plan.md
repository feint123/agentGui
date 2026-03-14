# Git 面板 UI 交互优化与中文路径修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 提升现有 Git 面板的 UI 和交互质量，并修复中文文件名/目录名在状态读取、diff、文件操作中的错误处理，同时补齐自动化 UI 测试。

**Architecture:** 继续沿用现有 `GitService -> GitPanelViewModel -> GitPanelView / GitDiffView / WorkspacePanelView` 分层，不引入新的持久化模型。中文路径问题优先在 Git 命令参数和状态解析层收敛，UI 优化只消费统一后的路径与状态。UI 测试使用真实临时 Git 仓库夹具，而不是 mock `GitService`，这样可以直接覆盖中文路径、diff 和文件级动作的端到端行为。

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`, Swift Testing, XCTest UI Testing, existing `WorkspaceState`, `TestLaunchOptions`, and the macOS app’s current in-memory UI-test launch mode.

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 所有功能改动先写失败测试，再补最小实现。
- 中文路径问题先在 service 和 parser 层解决，不在 view 层做补丁式兼容。
- UI 改动优先增加可观测性和一致性，不做与需求无关的视觉重构。
- UI 测试必须跑真实 Git 命令，覆盖至少一条中文路径端到端链路。
- 每个任务完成后都提交一次小而明确的 commit。

## 2. 目标文件清单

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitStatusParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`

### 主要测试文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitStatusParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

### 建议新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitPanelUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitUITestRepositoryFixture.swift`

## 3. 关键架构决策

### 3.1 中文路径修复策略

不要把中文路径问题留给 SwiftUI 层兜底。应在 `GitService` 与 `GitStatusParser` 中统一解决：

- Git 状态命令显式关闭 quote path，避免默认输出把中文转为八进制转义
- 解析器增加对 quoted path、rename path、带空格路径的规范化能力
- UI 和命令执行都使用同一份规范化后的 `relativePath`

### 3.2 Git UI 状态同步策略

Git 面板、文件树、diff 视图要共享统一的选中语义：

- `WorkspaceState` 继续负责跨视图的 diff 预览状态
- `GitPanelViewModel` 负责分组折叠、当前选中变更、提交区强调状态、错误提示
- `WorkspacePanelView` 与 `GitPanelView` 都根据同一份选中信息渲染高亮

### 3.3 UI 测试策略

UI 测试不要依赖假数据字符串模拟 Git 结果，而是创建一个真实临时仓库：

- 在 UI test target 内用 `Process` 执行 `git init`、`git add`、`git commit`
- 在临时目录中创建中文文件、中文目录、rename 场景
- 通过 `-com.agentgui.test.workingDirectory` 把仓库路径注入应用
- 断言 Git 面板和 diff 视图中的文本、按钮与状态变化

## 4. 任务拆解

### Task 1: 收紧 Git 状态解析契约，修复中文路径与 rename 路径

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitStatusParser.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitStatusParserTests.swift`

**Step 1: 写失败测试，固定中文路径与 quoted path 行为**

在 `GitStatusParserTests.swift` 中新增以下测试：

- 解析中文未跟踪路径，例如 `?? 文档/需求说明.md`
- 解析带空格中文路径，例如 `?? 设计稿/版本 2/提交说明.swift`
- 解析中文 rename 行，例如 `R  旧目录/说明.txt -> 新目录/产品说明.txt`
- 解析被引号包裹的 rename 路径，例如 `R  "旧 目录/说明.txt" -> "新 目录/产品说明.txt"`
- 解析 quoted path 时不会把 `\346\234\254` 一类转义残留到 `relativePath`

测试示例：

```swift
@Test func parsesChineseRenamePathAndKeepsNewPath() throws {
    let output = """
    ## main
    R  旧目录/说明.txt -> 新目录/产品说明.txt
    """

    let snapshot = try GitStatusParser.parseStatus(
        output,
        repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
    )

    #expect(snapshot.stagedChanges.count == 1)
    #expect(snapshot.stagedChanges.first?.relativePath == "新目录/产品说明.txt")
    #expect(snapshot.stagedChanges.first?.status == .renamed)
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitStatusParserTests
```

Expected: FAIL，原因应为中文路径/quoted path/rename 解析还不完整。

**Step 3: 写最小实现**

在 `GitStatusParser.swift` 中新增最小路径规范化逻辑：

- 为普通 path 增加 `normalizePath(_:)`
- 为 rename path 增加 `splitRenamePath(_:)`
- 若 path 被双引号包裹，则先解包，再处理 `\"`、`\\` 等最小转义
- UI 展示和后续命令执行一律使用规范化后的新路径

建议实现形态：

```swift
private static func normalizePath(_ rawPath: String) -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
    if let rename = splitRenamePath(trimmed) {
        return rename.newPath
    }
    return unquoteGitPath(trimmed)
}
```

**Step 4: 运行测试确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/GitStatusParser.swift agentGuiTests/GitStatusParserTests.swift
git commit -m "fix: parse git status paths with chinese filenames"
```

### Task 2: 修复 GitService 命令边界，保证中文路径命令参数与状态输出一致

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/GitService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitServiceTests.swift`

**Step 1: 写失败测试，固定 command runner 调用契约**

在 `GitServiceTests.swift` 中新增以下测试：

- `repositorySnapshot(for:)` 调用 `status` 时显式带上 `-c core.quotepath=false`
- `diff(for:)` 在中文路径文件上仍通过参数数组传递完整路径
- `stage(path:)`、`unstage(path:)`、`discard(path:)`、`cleanUntracked(path:)` 对中文路径参数保持原样
- 若 Git 返回“pathspec did not match”一类错误，service 转换为用户态错误，而不是把原始路径编码直接传上去

测试示例：

```swift
@Test func stagePreservesChinesePathArgument() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
    runner.results = [.success(.init(stdout: "", stderr: "", exitCode: 0))]

    try await service.stage(path: "文档/需求说明.md", repositoryRoot: repositoryRoot)

    #expect(runner.invocations[0].arguments == ["add", "--", "文档/需求说明.md"])
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitServiceTests
```

Expected: FAIL，原因应为当前 `status` 命令参数和错误映射不足。

**Step 3: 写最小实现**

在 `GitService.swift` 中：

- 将 `status` 命令调整为 `git -c core.quotepath=false status --porcelain=v1 --branch`
- 保持所有路径类命令继续使用参数数组，不引入 shell 拼接
- 为常见 pathspec / stale-path 错误补一层用户态映射，例如 `文件状态已变化，请刷新后重试。`

建议实现片段：

```swift
let result = try await commandRunner.run(
    arguments: ["-c", "core.quotepath=false", "status", "--porcelain=v1", "--branch"],
    workingDirectory: repositoryRoot
)
```

**Step 4: 运行测试确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/GitService.swift agentGuiTests/GitServiceTests.swift
git commit -m "fix: preserve chinese git paths in service commands"
```

### Task 3: 扩展 ViewModel 状态，收敛分组折叠、选中同步与提交区强调逻辑

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: 写失败测试，固定交互状态流转**

在 `GitPanelViewModelTests.swift` 中新增以下测试：

- 选中某个 change 进入 diff 后，ViewModel 能记录当前选中项和 staged/unstaged 来源
- 刷新后若该文件仍存在，选中态保持；若已消失，则清空 diff 选中
- `stagedChanges` 为空时，提交区应处于弱化状态；有 staged 变更时自动提升可见性
- 分组折叠状态在普通刷新后保持，不因一次操作刷新被重置
- 中文路径 change 在 `selectDiff`、`stage`、`confirmPendingAction` 后仍使用相同路径

测试示例：

```swift
@Test func selectDiffKeepsChinesePathSelectionState() async throws {
    let service = FakeGitService()
    service.diffText = "diff --git a/文档/需求说明.md b/文档/需求说明.md"
    let viewModel = GitPanelViewModel(gitService: service)
    let workspaceState = WorkspaceState()
    let change = GitFileChange(
        relativePath: "文档/需求说明.md",
        absoluteURL: URL(fileURLWithPath: "/tmp/repo/文档/需求说明.md"),
        status: .modified,
        section: .modified
    )

    await viewModel.selectDiff(for: change, staged: false, workspaceState: workspaceState)

    #expect(viewModel.selectedChange?.relativePath == "文档/需求说明.md")
    #expect(workspaceState.selectedGitDiffTitle == "文档/需求说明.md")
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: FAIL，原因应为新状态字段和刷新保持逻辑尚未实现。

**Step 3: 写最小实现**

在 `GitPanelViewModel.swift` 和 `WorkspaceState.swift` 中新增最小状态：

- 分组展开状态，例如 `expandedSections: Set<GitChangeSection>`
- 当前高亮 change 标识，例如 `selectedChangeID`
- 当前 diff 来源，例如 `selectedDiffSection`
- 提交区可见性判断，例如 `shouldEmphasizeCommitComposer`
- 当刷新后的 snapshot 不再包含当前选中 change 时，调用 `workspaceState.clearGitDiffSelection()`

**Step 4: 运行测试确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGui/Utilities/WorkspaceState.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "feat: sync git panel selection and composer state"
```

### Task 4: 重构 GitPanelView 与 GitDiffView，补齐主流 Source Control 交互和可测性

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitPanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 写失败测试，先固定 UI 可观测性需求**

先在计划中定义将要暴露的 accessibility identifiers，并为随后 UI tests 预留：

- `git.panel`
- `git.summary.repository`
- `git.summary.branch`
- `git.section.staged`
- `git.section.modified`
- `git.section.untracked`
- `git.commit.message`
- `git.commit.submit`
- `git.diff.header`
- `git.diff.path`

如果 `GitDiffView` 的主体在 UI 测试中不稳定，则增加一个 UI-test-only 可见文本镜像，例如：

```swift
if TestLaunchOptions.current.isUITestMode {
    Text(title)
        .accessibilityIdentifier("git.diff.path")
}
```

**Step 2: 运行已有相关测试并确认当前还不具备稳定定位能力**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/GitPanelUITests
```

Expected: FAIL，若测试文件尚不存在则在下一步新增。

**Step 3: 写最小实现**

在 `GitPanelView.swift` 中完成以下最小改造：

- 顶部摘要区强化层次，分离仓库名、分支、统计和刷新入口
- 分组标题加入数量和折叠/展开入口
- 文件项增加明确选中态和悬浮动作
- 文件项支持 `contextMenu`，至少包含 `查看 diff`、`暂存/取消暂存`、`丢弃/删除`
- 提交区在 `shouldEmphasizeCommitComposer == false` 时弱化展示
- 增加 UI 测试所需 accessibility identifiers

在 `GitDiffView.swift` 中完成以下最小改造：

- header 中显式展示当前路径和 diff 类型
- 返回按钮、标题、增删统计位置更稳定
- 空 diff / 二进制 diff 时展示明确占位文案
- 增加 `git.diff.header` 和 `git.diff.path`

在 `WorkspacePanelView.swift` 中完成以下最小改造：

- 文件树项高亮与 Git 面板选中 change 对齐
- 从文件树触发的 diff 仍走统一状态更新路径

**Step 4: 运行单元测试确认未破坏现有 Git 逻辑**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/GitPanelViewModelTests -only-testing:agentGuiTests/GitDiffPresentationTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/GitPanelView.swift agentGui/Views/GitDiffView.swift agentGui/Views/WorkspacePanelView.swift
git commit -m "feat: improve git panel interaction and diff navigation"
```

### Task 5: 建立 Git UI 测试夹具，覆盖真实仓库与中文路径场景

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitUITestRepositoryFixture.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/UITestBase.swift`

**Step 1: 写失败测试前先设计测试夹具接口**

新增一个 UI test helper，负责：

- 创建临时目录
- `git init`
- 配置 `user.name` 与 `user.email`
- 写入初始文件并提交第一版
- 创建中文路径文件、修改文件、未跟踪文件、rename 文件场景

建议接口：

```swift
struct GitUITestRepositoryFixture {
    let rootURL: URL
    let modifiedFileURL: URL
    let untrackedFileURL: URL
    let renamedFileURL: URL

    static func makeChineseFixture() throws -> GitUITestRepositoryFixture
    func cleanup() throws
}
```

**Step 2: 新增 helper 并用最小测试验证仓库夹具可创建**

先写一个最小 UI test 或 helper-level XCTest，确认：

- 仓库能初始化成功
- `git status --porcelain=v1 --branch` 能看到中文路径

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/GitPanelUITests/testGitFixtureLaunchesWithChineseChanges
```

Expected: FAIL，直到夹具和首个 UI test 建好。

**Step 3: 写最小实现**

在 helper 中使用 `Process` 跑 Git，保持参数数组，不拼接 shell 字符串。若命令失败，直接 `XCTFail` 并打印 stdout/stderr。

可复用的 helper：

```swift
@discardableResult
func runGit(_ arguments: [String], at rootURL: URL) throws -> String
```

**Step 4: 运行首个 UI test 确认夹具可用**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiUITests/GitUITestRepositoryFixture.swift agentGuiUITests/UITestBase.swift agentGuiUITests/GitPanelUITests.swift
git commit -m "test: add git ui test repository fixture"
```

### Task 6: 编写 GitPanelUITests，覆盖 UI 交互和中文路径回归

**Files:**
- Create or Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/GitPanelUITests.swift`

**Step 1: 写失败 UI tests，覆盖核心用户路径**

新增以下 UI tests：

- `testGitPanelShowsRepositorySummaryAndSectionCounts()`
- `testSelectingChineseChangedFileOpensDiffPreview()`
- `testContextMenuStageOnChineseFileRefreshesPanelState()`
- `testChineseUntrackedFileCanBeDeletedAfterConfirmation()`
- `testCommitComposerBecomesProminentWhenStagedChangesExist()`

重点断言：

- 仓库名、分支名、分组标题可见
- 中文路径文本正确显示，不包含转义乱码
- 点击文件项后 `git.diff.path` 显示正确中文路径
- 执行动作后列表状态变化，例如从 `已修改` 进入 `已暂存`
- 删除未跟踪文件时出现确认，再操作成功

示例测试骨架：

```swift
@MainActor
func testSelectingChineseChangedFileOpensDiffPreview() throws {
    let fixture = try GitUITestRepositoryFixture.makeChineseFixture()
    defer { try? fixture.cleanup() }

    launchApp(arguments: [
        "-com.agentgui.test.workingDirectory", fixture.rootURL.path
    ])

    let changedRow = app.staticTexts["需求说明.md"]
    XCTAssertTrue(changedRow.waitForExistence(timeout: 5))
    changedRow.click()

    XCTAssertTrue(app.staticTexts["文档/需求说明.md"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Patch Preview"].waitForExistence(timeout: 5))
}
```

**Step 2: 运行 UI tests 确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/GitPanelUITests
```

Expected: FAIL，原因应为 UI 标识、交互和状态同步尚未补齐。

**Step 3: 写最小实现直到通过**

按测试失败点补齐：

- 缺失的 accessibility identifiers
- 分组标题和计数文案
- 选中态与 diff header 文案
- 确认对话框按钮文案
- 操作后状态刷新与列表迁移

**Step 4: 运行 UI tests 确认通过**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGuiUITests/GitPanelUITests.swift agentGui/Views/GitPanelView.swift agentGui/Views/GitDiffView.swift agentGui/Views/WorkspacePanelView.swift
git commit -m "test: cover git panel ui flows with chinese paths"
```

### Task 7: 全量回归并更新需求关联文档

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-11-git-panel-ui-and-chinese-path-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-git-panel-ui-and-chinese-path-implementation-plan.md`

**Step 1: 运行 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/GitStatusParserTests \
  -only-testing:agentGuiTests/GitServiceTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests \
  -only-testing:agentGuiTests/GitDiffPresentationTests \
  -only-testing:agentGuiUITests/GitPanelUITests
```

Expected: PASS。

**Step 2: 运行仓库现有质量烟测**

Run VS Code task: `Quality Smoke`

Expected: PASS，或只暴露与本次改动无关的既有问题。

**Step 3: 更新文档状态说明**

在 spec 中补一小段“实现注意事项”或将已确认的技术决定同步回需求文档，避免 spec 与最终实现脱节。

**Step 4: 最终 Commit**

```bash
git add docs/spec/2026-03-11-git-panel-ui-and-chinese-path-requirements.md docs/plans/2026-03-11-git-panel-ui-and-chinese-path-implementation-plan.md
git commit -m "docs: finalize git panel ui and chinese path rollout plan"
```

## 5. 风险与检查点

- 风险 1：Git quoted path 与 rename path 的组合格式比当前预估更复杂。
  检查点：Task 1 完成后，先用真实 Git 输出样本补一轮 parser tests。

- 风险 2：macOS UI tests 对 SwiftUI 列表 hover/context menu 的稳定性不足。
  检查点：优先断言可见文本和按钮，不把 hover 本身当作唯一入口；必要时补充常驻按钮或 context menu 以外的测试路径。

- 风险 3：列表刷新后选中项丢失，导致 UI tests 脆弱。
  检查点：Task 3 完成后，先锁定选中保持规则，再推进 UI tests。

## 6. 完成定义

满足以下条件视为完成：

- 中文路径在 parser、service、view model、UI 四层都有自动化覆盖
- Git 面板支持更清晰的摘要层级、分组折叠、文件选中态和上下文操作
- 从文件树和 Git 面板进入 diff 的路径一致，返回行为稳定
- 至少一组 UI tests 使用真实临时 Git 仓库验证中文文件路径工作流
- focused tests 与 `Quality Smoke` 完成验证