# Workspace File Tree Baseline Upgrade Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 完善左侧文件树的基础能力，交付“在访达中打开”、多选、批量拖拽移动、默认折叠后可展开的搜索按钮，以及一组调研后补上的基础交互能力。

**Architecture:** 保持现有 `WorkspacePanelView -> WorkspaceTreeViewModel -> WorkspaceTreeActionHandler / WorkspaceFileTreeOperations / WorkspaceTreeRefreshCoordinator` 分层，不把文件树行为直接塞进 SwiftUI 视图。多选、批量动作、搜索展示状态和拖拽校验先沉到 ViewModel 与 utility 层，再由 `WorkspacePanelView` 做最薄的 UI 绑定；Finder 打开能力通过可替换 service 封装，保证单元测试可控。拖拽移动继续依赖文件系统真实操作，并复用现有 refresh/selection remap 机制，避免做第二套树状态源。

**Tech Stack:** Swift 6、SwiftUI、AppKit `NSWorkspace`、Foundation `FileManager`、Swift Testing、XCTest UI Testing、现有 `WorkspacePanelView` / `WorkspaceTreeViewModel` / `WorkspaceTreeRefreshCoordinator` / `WorkspaceFileTreeOperations`。

---

## 1. 实施原则

- 我正在使用 writing-plans skill 来创建这份 implementation plan。
- 先锁定失败测试，再补最小实现，不先改 UI 外观。
- 多选、拖拽、Finder 打开都必须支持中文路径与多文件场景。
- 搜索折叠动画要可见，但测试不要依赖动画帧；用可观测状态和标识符断言。
- 拖拽必须先做非法目标校验，禁止把目录拖入自身或后代目录，禁止无意义同目录 no-op 扰动。
- 每个任务完成后都提交一个小而明确的 commit。

## 2. 这次一起补齐的基础能力

除你明确点名的能力外，基于当前实现缺口，建议把以下基础能力一起纳入本次范围：

1. 批量路径动作：多选后除了“在访达中打开”，再补一个“复制相对路径”，否则批量选择只剩删除/拖拽，价值偏低。
2. 搜索键盘语义：`Escape` 清空并折叠搜索，避免展开后只能鼠标收起；当搜索有唯一文件结果时，`Return` 直接打开该文件。
3. 拖拽安全护栏：禁止拖入自身/后代目录、禁止重名覆盖、禁止把选中集合再次拖回原父目录触发伪刷新。
4. 选择稳态：外部文件系统刷新、重命名、拖拽移动后，主选中项和批量选中集合要一起 remap / 清理，不能只维护单个 `selectedTreeNodeID`。

这四项都属于“基础能力”，不是后续增强项。计划默认一并落地。

## 3. 目标文件清单

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeActionHandler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileTreeOperations.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkspacePanelUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceFileTreeOperationsTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeActionHandlerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeSnapshotOpsTests.swift`

### 建议新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkspaceRevealService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeDropCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceRevealServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift`

## 4. 关键设计决定

### 4.1 多选状态模型

不要继续把文件树当成“只有一个 `selectedTreeNodeID` 的单选面板”。建议把状态拆成：

- `primarySelectionID: URL?`，用于工具栏动作、重命名目标、搜索回车打开目标
- `selectedTreeNodeIDs: Set<URL>`，用于批量删除、批量 Finder 打开、批量拖拽

单击某一项时，默认行为仍然是“单选 + 更新 primary selection”；命令键切换某一项的勾选状态；目录也允许加入批量选择，但“重命名”始终只作用于 `primarySelectionID`。

### 4.2 Finder 打开语义

在 macOS 上，“在访达中打开”优先实现为 `NSWorkspace.shared.activateFileViewerSelecting(_:)`，因为它天然支持多选并能高亮目标，而不是仅仅 `open(_:)` 父目录。

建议抽象：

```swift
protocol WorkspaceRevealServing {
    func revealInFinder(_ urls: [URL])
}
```

生产实现做去重、标准化路径、空数组 no-op；测试实现只记录调用参数。

### 4.3 拖拽数据与批量移动语义

拖拽不要把移动逻辑埋在 `View.onDrop` 闭包里。应显式抽象一个 drop coordinator：

```swift
struct WorkspaceTreeDropCoordinator {
    func proposal(for draggedURLs: Set<URL>, destination: FileNode?) -> WorkspaceTreeDropPlan?
}
```

它负责：

- 解析拖拽目标目录
- 拒绝非法目标
- 生成待移动 URL 列表与目的目录
- 交给 `WorkspaceFileTreeOperations.moveItems(at:to:)` 执行

### 4.4 搜索折叠展示策略

搜索默认收起成一个按钮；点击后以短时长动画展开输入框。测试不读动画帧，而是断言：

- `workspace.searchToggleButton` 存在
- `workspace.searchContainer.collapsed` / `workspace.searchContainer.expanded` 状态切换
- `Escape` 后回到 collapsed 状态

ViewModel 至少需要：

```swift
enum WorkspaceSearchPresentationState {
    case collapsed
    case expanded
}
```

### 4.5 这次一并加入的基础动作

除了 Finder 打开，再在上下文菜单和批量动作栏加入：

- `复制相对路径`
- `清空并收起搜索`
- 唯一搜索结果按回车直接打开

这些能力代码成本低，但能显著减少“多选了却什么也做不了”的空洞感。

## 5. 任务拆解

### Task 1: 锁定多选、搜索折叠和 Finder 打开的行为契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceRevealServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkspacePanelUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`

**Step 1: 写 ViewModel 失败测试，固定多选和搜索状态机**

在 `WorkspaceTreeViewModelTests.swift` 中新增这些测试：

```swift
@MainActor
@Test func commandToggleKeepsPrimarySelectionAndAddsSecondarySelection() {
    let viewModel = WorkspaceTreeViewModel()
    let readme = FileNode(id: URL(fileURLWithPath: "/tmp/ws/README.md"), name: "README.md", isDirectory: false, children: nil)
    let notes = FileNode(id: URL(fileURLWithPath: "/tmp/ws/Notes.md"), name: "Notes.md", isDirectory: false, children: nil)

    viewModel.rootNodes = [readme, notes]
    viewModel.selectNode(readme, additive: false, workspaceState: WorkspaceState())
    viewModel.selectNode(notes, additive: true, workspaceState: WorkspaceState())

    #expect(viewModel.primarySelectionID == notes.id.standardizedFileURL)
    #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL, notes.id.standardizedFileURL])
}
```

```swift
@MainActor
@Test func escapeClearsSearchQueryAndCollapsesSearchPresentation() {
    let viewModel = WorkspaceTreeViewModel()
    viewModel.expandSearch()
    viewModel.treeSearchText = "note"

    viewModel.collapseSearch()

    #expect(viewModel.treeSearchText.isEmpty)
    #expect(viewModel.searchPresentationState == .collapsed)
}
```

**Step 2: 写 Finder service 失败测试**

在 `WorkspaceRevealServiceTests.swift` 中锁定批量 reveal 的标准化与去重语义：

```swift
@Test func revealInFinderDeduplicatesStandardizedURLs() {
    let workspace = RecordingNSWorkspaceClient()
    let service = WorkspaceRevealService(client: workspace)
    let raw = URL(fileURLWithPath: "/tmp/ws/Docs/../Docs/Readme.md")

    service.revealInFinder([raw, raw.standardizedFileURL])

    #expect(workspace.revealedURLGroups == [[raw.standardizedFileURL]])
}
```

**Step 3: 写 UI 失败测试，固定搜索按钮默认收起与展开行为**

在 `WorkspacePanelUITests.swift` 中新增：

```swift
@MainActor
func testWorkspaceSearchStartsCollapsedAndExpandsWhenButtonClicked() throws {
    let fixture = try makeWorkspaceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    launchApp(arguments: [
        "-com.agentgui.test.workingDirectory", fixture.rootURL.path,
        "-com.agentgui.test.preloadMessages", "false"
    ])

    XCTAssertTrue(app.buttons["workspace.searchToggleButton"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["搜索文件或文件夹"].exists)

    app.buttons["workspace.searchToggleButton"].click()

    XCTAssertTrue(app.textFields["搜索文件或文件夹"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["workspace.searchPresentation.expanded"].waitForExistence(timeout: 3))
}
```

**Step 4: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/WorkspaceRevealServiceTests \
  -only-testing:agentGuiUITests/WorkspacePanelUITests/testWorkspaceSearchStartsCollapsedAndExpandsWhenButtonClicked
```

Expected: FAIL，因为多选状态、Finder reveal service 和搜索折叠 UI 还不存在。

**Step 5: 提交失败测试**

```bash
git add agentGuiTests/WorkspaceTreeViewModelTests.swift \
        agentGuiTests/WorkspaceRevealServiceTests.swift \
        agentGuiUITests/WorkspacePanelUITests.swift \
        agentGui/Utilities/TestLaunchOptions.swift
git commit -m "test: lock workspace tree selection and search contracts"
```

### Task 2: 实现多选状态机与批量动作入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeActionHandler.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`

**Step 1: 在 ViewModel 中加入 primary selection + selection set**

最小实现方向：

```swift
var primarySelectionID: URL?
var selectedTreeNodeIDs: Set<URL> = []

func selectNode(_ node: FileNode, additive: Bool, workspaceState: WorkspaceState) {
    let standardizedID = node.id.standardizedFileURL
    if additive {
        if selectedTreeNodeIDs.contains(standardizedID) {
            selectedTreeNodeIDs.remove(standardizedID)
        } else {
            selectedTreeNodeIDs.insert(standardizedID)
        }
        primarySelectionID = standardizedID
    } else {
        selectedTreeNodeIDs = [standardizedID]
        primarySelectionID = standardizedID
    }

    if !node.isDirectory {
        workspaceState.clearGitDiffSelection()
        workspaceState.selectedFile = standardizedID
    }
}
```

**Step 2: 让现有单项动作全部走 primary selection**

更新这些 API：

- `selectedNode()` 改为读取 `primarySelectionID`
- `confirmDelete(_:)` 支持“没有显式入参时默认批量选中集合”
- `beginRename(for:)` 明确拒绝多选重命名

**Step 3: 扩展 selection remap / deletion 清理逻辑**

让 `WorkspaceTreeActionHandler` 支持一组 URL，而不是只 remap 一个字段：

```swift
struct WorkspaceTreeSelectionSnapshot: Equatable {
    var primarySelectionID: URL?
    var selectedTreeNodeIDs: Set<URL>
    var selectedFile: URL?
    var selectedGitDiffPath: URL?
}
```

删除或移动后必须同时修正：

- primary selection
- 批量选中集合
- 当前打开文件
- 当前 diff 选中

**Step 4: 跑 focused unit tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/WorkspaceTreeActionHandlerTests
```

Expected: PASS。

**Step 5: 提交多选状态机**

```bash
git add agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGui/Utilities/WorkspaceTreeActionHandler.swift \
        agentGuiTests/WorkspaceTreeViewModelTests.swift \
        agentGuiTests/WorkspaceTreeActionHandlerTests.swift
git commit -m "feat: add workspace tree multi-selection state"
```

### Task 3: 实现 Finder 打开与批量相对路径复制

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkspaceRevealService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceRevealServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`

**Step 1: 定义 Finder reveal service 与测试替身**

```swift
protocol WorkspaceRevealServing {
    func revealInFinder(_ urls: [URL])
}

struct WorkspaceRevealService: WorkspaceRevealServing {
    func revealInFinder(_ urls: [URL]) {
        let normalized = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        guard !normalized.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(normalized)
    }
}
```

**Step 2: 在 ViewModel 中加入批量动作 helper**

加入：

- `selectedNodes()`
- `revealSelectionInFinder()`
- `relativePathsForSelection(root:)`

复制相对路径可以先用换行拼接：

```swift
let joined = relativePaths.sorted().joined(separator: "\n")
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(joined, forType: .string)
```

**Step 3: 在 WorkspacePanelView 中暴露动作入口**

至少加两处入口：

- 行级 `contextMenu`
- 工具栏批量动作按钮或 `Menu`

建议按钮文案：

- `在访达中打开`
- `复制相对路径`

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceRevealServiceTests \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests
```

Expected: PASS。

**Step 5: 提交 Finder 与批量动作**

```bash
git add agentGui/Services/WorkspaceRevealService.swift \
        agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGui/Views/WorkspacePanelView.swift \
        agentGuiTests/WorkspaceRevealServiceTests.swift \
        agentGuiTests/WorkspaceTreeViewModelTests.swift
git commit -m "feat: add finder reveal and batch path actions"
```

### Task 4: 锁定批量拖拽移动与非法目标校验

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeDropCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceFileTreeOperationsTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeActionHandlerTests.swift`

**Step 1: 写 drop coordinator 失败测试**

新增这些测试：

```swift
@Test func rejectsDroppingDirectoryIntoItsOwnDescendant() {
    let sources = URL(fileURLWithPath: "/tmp/ws/Sources")
    let child = sources.appending(path: "Feature")
    let destination = FileNode(id: child, name: "Feature", isDirectory: true, children: [])

    let plan = WorkspaceTreeDropCoordinator().proposal(for: [sources], destination: destination)

    #expect(plan == nil)
}
```

```swift
@Test func ignoresNoOpMoveBackIntoSameParentDirectory() {
    let file = URL(fileURLWithPath: "/tmp/ws/Docs/Readme.md")
    let destination = FileNode(id: URL(fileURLWithPath: "/tmp/ws/Docs"), name: "Docs", isDirectory: true, children: [])

    let plan = WorkspaceTreeDropCoordinator().proposal(for: [file], destination: destination)

    #expect(plan == nil)
}
```

**Step 2: 写批量移动文件系统失败测试**

在 `WorkspaceFileTreeOperationsTests.swift` 中新增：

```swift
@Test func moveItemsRelocatesMultipleFilesIntoTargetDirectory() throws {
    let root = try makeWorkspaceOperationsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let docs = try WorkspaceFileTreeOperations.createDirectory(named: "Docs", in: root)
    let archive = try WorkspaceFileTreeOperations.createDirectory(named: "Archive", in: root)
    let readme = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: docs)
    let notes = try WorkspaceFileTreeOperations.createFile(named: "Notes.md", in: docs)

    let moved = try WorkspaceFileTreeOperations.moveItems(at: [readme, notes], to: archive)

    #expect(moved == [archive.appending(path: "README.md"), archive.appending(path: "Notes.md")])
}
```

**Step 3: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeDropCoordinatorTests \
  -only-testing:agentGuiTests/WorkspaceFileTreeOperationsTests \
  -only-testing:agentGuiTests/WorkspaceTreeActionHandlerTests
```

Expected: FAIL，因为 drop coordinator 和批量 move API 还不存在。

**Step 4: 提交失败测试**

```bash
git add agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift \
        agentGuiTests/WorkspaceFileTreeOperationsTests.swift \
        agentGuiTests/WorkspaceTreeActionHandlerTests.swift
git commit -m "test: lock workspace tree drag and drop rules"
```

### Task 5: 实现批量拖拽移动与选择 remap

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeDropCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceFileTreeOperations.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceTreeActionHandler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceFileTreeOperationsTests.swift`

**Step 1: 实现 drop proposal 计算**

`WorkspaceTreeDropCoordinator` 至少返回：

```swift
struct WorkspaceTreeDropPlan: Equatable {
    let draggedURLs: [URL]
    let destinationDirectory: URL
}
```

规则：

- 目标是文件时，真实目的地取其父目录
- 目标是目录时，真实目的地就是该目录
- 任一拖拽项是目标目录祖先时，返回 `nil`
- 所有拖拽项父目录都等于目的目录时，返回 `nil`

**Step 2: 在 `WorkspaceFileTreeOperations` 增加 `moveItems`**

```swift
static func moveItems(at urls: [URL], to destinationDirectory: URL) throws -> [URL] {
    try urls.map { url in
        let destinationURL = try validatedMoveDestination(for: url, to: destinationDirectory)
        try FileManager.default.moveItem(at: url.standardizedFileURL, to: destinationURL)
        return destinationURL
    }
}
```

这里要额外校验：

- 目标目录存在
- 目的地不得重名
- 不接受缺失文件

**Step 3: 在 ViewModel 中执行批量拖拽移动并刷新目录**

加入类似：

```swift
func moveSelection(to destination: FileNode, workspaceState: WorkspaceState) {
    guard let plan = dropCoordinator.proposal(for: selectedTreeNodeIDs, destination: destination) else { return }
    let movedURLs = try WorkspaceFileTreeOperations.moveItems(at: plan.draggedURLs, to: plan.destinationDirectory)
    applySelection(actionHandler.applyingMove(from: plan.draggedURLs, to: movedURLs, selection: currentSelectionSnapshot(workspaceState: workspaceState)), workspaceState: workspaceState)
}
```

**Step 4: 跑 focused unit tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeDropCoordinatorTests \
  -only-testing:agentGuiTests/WorkspaceFileTreeOperationsTests \
  -only-testing:agentGuiTests/WorkspaceTreeActionHandlerTests \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests
```

Expected: PASS。

**Step 5: 提交拖拽移动实现**

```bash
git add agentGui/Utilities/WorkspaceTreeDropCoordinator.swift \
        agentGui/Utilities/WorkspaceFileTreeOperations.swift \
        agentGui/Utilities/WorkspaceTreeActionHandler.swift \
        agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift \
        agentGuiTests/WorkspaceFileTreeOperationsTests.swift \
        agentGuiTests/WorkspaceTreeActionHandlerTests.swift \
        agentGuiTests/WorkspaceTreeViewModelTests.swift
git commit -m "feat: add workspace tree batch drag and drop"
```

### Task 6: 接入 SwiftUI 文件树 UI，多选手势、拖拽和上下文菜单

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkspacePanelUITests.swift`

**Step 1: 把行点击改成支持 additive selection**

`FileRowView` 增加：

- 普通点击
- 命令键点击
- 多选高亮态

必要时用 `NSEvent.modifierFlags.contains(.command)` 判断 additive selection。

**Step 2: 为文件树行接入拖拽与接收 drop**

建议最小实现：

```swift
.onDrag {
    treeViewModel.beginDragging(node)
    return NSItemProvider(object: node.id.path as NSString)
}
.onDrop(of: [.text], isTargeted: nil) { _ in
    treeViewModel.handleDrop(on: node, workspaceState: workspaceState)
}
```

拖拽开始时，如果当前行不在多选集合里，先切回单选并以它作为拖拽集合；如果当前行已在多选集合中，则拖拽整个已选集合。

**Step 3: 更新上下文菜单与批量工具栏状态**

上下文菜单至少包含：

- `在访达中打开`
- `复制相对路径`
- `新建文件`
- `新建文件夹`
- `重命名`
- `删除`

其中：

- 多选时禁用 `重命名`
- 无 selection 时禁用批量动作按钮

**Step 4: 跑 focused UI tests**

补充这些 UI 测试：

- 搜索默认收起，点击按钮后展开
- 多选后批量动作按钮变为 enabled
- `Escape` 后搜索收起
- 右键或工具栏可见 `在访达中打开`

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiUITests/WorkspacePanelUITests
```

Expected: PASS；如果拖拽手势 UI 自动化不稳定，保留单元测试为主，并在文档末尾补手工验收项。

**Step 5: 提交 UI 集成**

```bash
git add agentGui/Views/WorkspacePanelView.swift \
        agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGuiUITests/WorkspacePanelUITests.swift
git commit -m "feat: wire workspace tree multi-select actions into UI"
```

### Task 7: 把搜索改为默认折叠按钮，并补上动画与键盘语义

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkspacePanelUITests.swift`

**Step 1: 写失败测试，锁定 `Escape` 和唯一结果回车语义**

在 `WorkspaceTreeViewModelTests.swift` 或 `WorkspacePanelUITests.swift` 中新增：

```swift
@MainActor
@Test func returnOpensSingleFilteredFileResult() {
    let workspaceState = WorkspaceState()
    let viewModel = WorkspaceTreeViewModel()
    let notes = FileNode(id: URL(fileURLWithPath: "/tmp/ws/Notes.md"), name: "Notes.md", isDirectory: false, children: nil)

    viewModel.rootNodes = [notes]
    viewModel.expandSearch()
    viewModel.treeSearchText = "notes"

    viewModel.openSingleSearchResultIfPossible(workspaceState: workspaceState)

    #expect(workspaceState.selectedFile == notes.id.standardizedFileURL)
}
```

**Step 2: 实现折叠/展开动画**

`WorkspacePanelView` 中把常驻输入框改成：

```swift
if treeViewModel.searchPresentationState == .expanded {
    searchField
        .transition(.move(edge: .trailing).combined(with: .opacity))
} else {
    Button(action: treeViewModel.expandSearch) {
        Image(systemName: "magnifyingglass")
    }
    .accessibilityIdentifier("workspace.searchToggleButton")
}
```

建议动画：

```swift
withAnimation(.easeInOut(duration: 0.18))
```

**Step 3: 加入 UI 可观测标识**

仅在 UI test mode 下输出：

- `workspace.searchPresentation.collapsed`
- `workspace.searchPresentation.expanded`

不要让测试去猜动画何时结束。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiUITests/WorkspacePanelUITests
```

Expected: PASS。

**Step 5: 提交搜索折叠与动画**

```bash
git add agentGui/Views/WorkspacePanelView.swift \
        agentGui/ViewModels/WorkspaceTreeViewModel.swift \
        agentGui/Utilities/TestLaunchOptions.swift \
        agentGuiUITests/WorkspacePanelUITests.swift \
        agentGuiTests/WorkspaceTreeViewModelTests.swift
git commit -m "feat: add collapsible animated workspace search"
```

### Task 8: 补强基础稳态与回归验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeSnapshotOpsTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeActionHandlerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkspacePanelUITests.swift`

**Step 1: 补充回归测试**

新增覆盖：

- 中文路径批量 reveal 不丢失标准化路径
- 外部刷新后已删除项会从 `selectedTreeNodeIDs` 中清理
- 搜索中祖先目录保留行为不被折叠 UI 改坏
- 多选目录 + 文件混合时 `复制相对路径` 顺序稳定

**Step 2: 跑完整 focused suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/WorkspaceRevealServiceTests \
  -only-testing:agentGuiTests/WorkspaceTreeDropCoordinatorTests \
  -only-testing:agentGuiTests/WorkspaceFileTreeOperationsTests \
  -only-testing:agentGuiTests/WorkspaceTreeActionHandlerTests \
  -only-testing:agentGuiTests/WorkspaceTreeSnapshotOpsTests \
  -only-testing:agentGuiUITests/WorkspacePanelUITests
```

Expected: PASS。

**Step 3: 跑质量冒烟**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: 所有现有 smoke checks 通过；如果有与本需求无关的历史失败，单独记录，不在本任务顺手修 unrelated 问题。

**Step 4: 手工验收拖拽与 Finder 行为**

手工检查：

1. 多选两个文件，右键 `在访达中打开`，Finder 高亮两个目标。
2. 选择目录与文件混合集合，`复制相对路径` 得到稳定换行文本。
3. 把目录拖进自身子目录时，UI 不崩溃、不执行移动。
4. 搜索按钮默认折叠；展开后 `Escape` 收起；唯一结果按 `Return` 能打开文件。

**Step 5: 提交回归与验证收口**

```bash
git add agentGuiTests/WorkspaceTreeViewModelTests.swift \
        agentGuiTests/WorkspaceRevealServiceTests.swift \
        agentGuiTests/WorkspaceTreeDropCoordinatorTests.swift \
        agentGuiTests/WorkspaceFileTreeOperationsTests.swift \
        agentGuiTests/WorkspaceTreeActionHandlerTests.swift \
        agentGuiTests/WorkspaceTreeSnapshotOpsTests.swift \
        agentGuiUITests/WorkspacePanelUITests.swift
git commit -m "test: harden workspace tree baseline interactions"
```

## 6. 实施顺序建议

按下面顺序执行，不要打乱：

1. 先做 Task 1 和 Task 2，先把 selection model 立住。
2. 再做 Task 3，先让批量动作有真实价值。
3. 然后做 Task 4 和 Task 5，把拖拽 move 链路补齐。
4. 最后做 Task 6 到 Task 8，收 UI、动画和回归。

## 7. 风险提示

1. `List(children:)` 在 macOS SwiftUI 下对自定义多选和拖拽支持并不完美，如果手势冲突严重，不要硬扛系统 `List`；可以在同一任务里切换为 `ScrollView + OutlineGroup` 风格，但前提是保持现有 UI 测试可观测性。
2. Finder 打开是系统级动作，UI 自动化不适合验证 Finder 窗口本身；自动化测试只验证 service 被调用，Finder 实际高亮放到手工验收。
3. 拖拽移动会触发文件系统观察器回刷，务必让 selection remap 与 refresh 协调一致，否则 UI 会短暂选中幽灵节点。
