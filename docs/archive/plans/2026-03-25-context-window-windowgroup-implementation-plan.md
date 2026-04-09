# Context Window WindowGroup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将上下文窗口从单例 `Window` + 应用自绘 tab strip 改造成 data-driven `WindowGroup`，使用 macOS 原生 window tab bar 承载文件、Git diff 与 change proposal 上下文实例。

**Architecture:** 改造分四层推进。第一层引入 `WorkbenchContextSceneValue`，把“上下文标签页”重定义为可编码、可哈希的窗口实例值。第二层引入 `WorkbenchContextWindowRouter`，把 `WorkspaceState` 与 `openWindow(id:value:)` 解耦。第三层把 scene 从 `Window` 切到 data-driven `WindowGroup`，并把 `WorkbenchContextWindowView` 收缩成“单实例上下文渲染器”。第四层删除 `WorkbenchContextWindowState` 及其命令耦合，改用 macOS 原生窗口 tab 行为与 AppKit tabbing 配置。

**Tech Stack:** Swift 6, SwiftUI Scene API (`WindowGroup`, `openWindow`), AppKit (`NSWindow`, `tabbingIdentifier`, `tabbingMode`, `allowsAutomaticWindowTabbing`), Swift Testing, SwiftData。

---

## Design Inputs

- 设计文档：`/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-25-context-window-windowgroup-design.md`
- Apple 文档：
  - `https://developer.apple.com/documentation/swiftui/windowgroup`
  - `https://developer.apple.com/documentation/swiftui/window`
  - `https://developer.apple.com/documentation/appkit/nswindow/tabbingmode`
  - `https://developer.apple.com/documentation/appkit/nswindow/allowsautomaticwindowtabbing`
  - `https://developer.apple.com/documentation/appkit/nswindow/tabbingidentifier`

## Constraints

- 严格按 @test-driven-development 执行：任何生产代码变更前先写失败测试并验证失败原因正确。
- 不保留“应用层 tab strip”和“系统 window tab bar”双轨模式；最终应只剩系统窗口 tab 模型。
- `WorkbenchContextSceneValue` 必须轻量、`Hashable`、`Codable`，不能把整段 diff 文本直接塞进 scene value。
- 这次改造不重写 `FileEditorView`、`GitDiffView`、`ChangeProposalReviewView` 内部业务，只改上下文窗口承载方式。
- 如果某一阶段无法对 `WindowGroup` scene 声明做稳定单元测试，至少要先为纯逻辑 helper、router 和命令改造补充回归测试，再用 focused build/test 做编译级验证。

## File Inventory

### Create

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextSceneValue.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextWindowRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchContextWindowConfigurator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextSceneValueTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextWindowRouterTests.swift`

### Modify

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchSceneServices.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchContextWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRequirement.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Modules/WindowCommands.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchTitlePresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextWindowStateTests.swift`

### Delete

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextWindowState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextWindowStateTests.swift`

## Verification Commands

### Focused command/platform regression

使用已有 VS Code task：`Command Platform Focused Tests`

等价命令：

```bash
xcodebuild \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -derivedDataPath /tmp/agentGui-command-platform-derived-5 \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:agentGuiTests/AppCommandRouterTests \
  -only-testing:agentGuiTests/RecentWorkspaceStoreTests \
  -only-testing:agentGuiTests/RecentSessionProviderTests \
  -only-testing:agentGuiTests/CommandPaletteViewModelTests \
  -only-testing:agentGuiTests/WorkspaceFileSearchIndexTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 命令平台相关测试全部通过。

### Focused workbench/context regression

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-context-window-plan \
  -only-testing:agentGuiTests/WorkspaceStateTests \
  -only-testing:agentGuiTests/AppCommandRouterTests \
  -only-testing:agentGuiTests/AppCommandRegistryTests \
  -only-testing:agentGuiTests/WorkbenchTitlePresentationTests \
  -only-testing:agentGuiTests/WorkbenchContextSceneValueTests \
  -only-testing:agentGuiTests/WorkbenchContextWindowRouterTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: scene value、router、workspace state、command registry 与 title presentation 回归通过。

### Compile-health fallback

```bash
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-context-window-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: app 和 unit tests 编译通过；若存在环境级签名噪声，仅作为环境问题记录。

## Target Shapes

### Scene value

```swift
enum WorkbenchContextSceneValue: Hashable, Codable, Sendable {
    case file(path: String)
    case gitDiff(title: String, snapshotID: String)
    case changeProposal(proposalID: UUID, filePath: String?)

    init?(selection: WorkbenchDetailSelection, diffSnapshotStore: WorkbenchDiffSnapshotStore) {
        switch selection {
        case .none:
            return nil
        case .file(let fileURL):
            self = .file(path: fileURL.standardizedFileURL.path)
        case .gitDiff(let title, let diffText):
            let snapshotID = diffSnapshotStore.store(title: title, diffText: diffText)
            self = .gitDiff(title: title, snapshotID: snapshotID)
        case .changeProposal(let proposalID, let filePath):
            self = .changeProposal(proposalID: proposalID, filePath: filePath)
        }
    }
}
```

### Router

```swift
@MainActor
final class WorkbenchContextWindowRouter {
    typealias OpenWindowWithValue = @MainActor (_ id: String, _ value: WorkbenchContextSceneValue) -> Void

    private let openWindowWithValue: OpenWindowWithValue
    private let diffSnapshotStore: WorkbenchDiffSnapshotStore

    init(
        diffSnapshotStore: WorkbenchDiffSnapshotStore = .shared,
        openWindowWithValue: @escaping OpenWindowWithValue
    ) {
        self.diffSnapshotStore = diffSnapshotStore
        self.openWindowWithValue = openWindowWithValue
    }

    func open(selection: WorkbenchDetailSelection) {
        guard let value = WorkbenchContextSceneValue(selection: selection, diffSnapshotStore: diffSnapshotStore) else {
            return
        }

        openWindowWithValue(WorkbenchContextWindowScene.id, value)
    }
}
```

### Window AppKit configurator

```swift
struct WorkbenchContextWindowConfigurator: NSViewRepresentable {
    let title: String
    let subtitle: String
    let representedURL: URL?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView) }
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.title = title
        window.subtitle = subtitle
        window.representedURL = representedURL
        window.tabbingIdentifier = "workbench-context"
        window.tabbingMode = .preferred
    }
}
```

## Task Breakdown

### Task 1: 建立 scene value 与 diff snapshot 路由边界

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextSceneValue.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextSceneValueTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing test**

新增 `WorkbenchContextSceneValueTests`，锁定以下行为：

```swift
@Test func fileSelectionNormalizesToPathBackedSceneValue() {
    let fileURL = URL(fileURLWithPath: "/tmp/repo/File.swift")

    let value = WorkbenchContextSceneValue(
        selection: .file(fileURL),
        diffSnapshotStore: .inMemory
    )

    #expect(value == .file(path: fileURL.standardizedFileURL.path))
}

@Test func diffSelectionStoresSnapshotAndReturnsStableIdentifier() throws {
    let store = WorkbenchDiffSnapshotStore.inMemory
    let value = try #require(
        WorkbenchContextSceneValue(
            selection: .gitDiff(title: "A.swift", diffText: "diff --git a/A.swift b/A.swift"),
            diffSnapshotStore: store
        )
    )

    guard case .gitDiff(let title, let snapshotID) = value else {
        Issue.record("Expected gitDiff scene value")
        return
    }

    #expect(title == "A.swift")
    #expect(store.diffText(for: snapshotID) == "diff --git a/A.swift b/A.swift")
}
```

同时在 `WorkspaceStateTests` 先补一个失败用例，表达“只选择 detail，不再直接依赖 tab store”。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task1 -only-testing:agentGuiTests/WorkbenchContextSceneValueTests -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `WorkbenchContextSceneValue`、`WorkbenchDiffSnapshotStore.inMemory` 和新的行为尚不存在。

**Step 3: Write minimal implementation**

在 `WorkbenchContextSceneValue.swift` 中实现最小类型与 helper：

```swift
import Foundation

enum WorkbenchContextSceneValue: Hashable, Codable, Sendable {
    case file(path: String)
    case gitDiff(title: String, snapshotID: String)
    case changeProposal(proposalID: UUID, filePath: String?)
}

@MainActor
extension WorkbenchContextSceneValue {
    init?(
        selection: WorkbenchDetailSelection,
        diffSnapshotStore: WorkbenchDiffSnapshotStore
    ) {
        switch selection {
        case .none:
            return nil
        case .file(let fileURL):
            self = .file(path: fileURL.standardizedFileURL.path)
        case .gitDiff(let title, let diffText):
            self = .gitDiff(title: title, snapshotID: diffSnapshotStore.store(title: title, diffText: diffText))
        case .changeProposal(let proposalID, let filePath):
            self = .changeProposal(proposalID: proposalID, filePath: filePath)
        }
    }
}
```

如果仓库里还没有合适的 diff snapshot store，就在本任务内同时补一个最小内存实现，但不要在这一阶段接入 UI。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkbenchContextSceneValue.swift agentGuiTests/WorkbenchContextSceneValueTests.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "test: add context scene value coverage"
```

### Task 2: 引入 router，替换 WorkspaceState 对 tab store 的直接依赖

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextWindowRouter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextWindowRouterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchSceneServices.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing test**

新增 router tests，先锁定 `WorkspaceState` 不再操作 `WorkbenchContextWindowState`：

```swift
@Test func showFileDetailRoutesThroughContextWindowRouter() {
    let recorder = ContextWindowRouteRecorder()
    let router = WorkbenchContextWindowRouter(
        diffSnapshotStore: .inMemory,
        openWindowWithValue: recorder.openWindow
    )

    let workspaceState = WorkspaceState()
    workspaceState.contextWindowRouter = router

    workspaceState.showFileDetail(URL(fileURLWithPath: "/tmp/repo/file.swift"))

    #expect(recorder.values == [.file(path: "/tmp/repo/file.swift")])
}
```

同步把 `WorkspaceStateTests` 中现有 `showFileDetailOpensContextWindowTab` 改写为新的路由断言。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task2 -only-testing:agentGuiTests/WorkbenchContextWindowRouterTests -only-testing:agentGuiTests/WorkspaceStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `contextWindowRouter` 尚不存在，`WorkspaceState` 仍然依赖 `contextWindowState`。

**Step 3: Write minimal implementation**

```swift
@MainActor
final class WorkbenchContextWindowRouter {
    typealias OpenWindowWithValue = @MainActor (_ id: String, _ value: WorkbenchContextSceneValue) -> Void

    private let openWindowWithValue: OpenWindowWithValue
    private let diffSnapshotStore: WorkbenchDiffSnapshotStore

    init(diffSnapshotStore: WorkbenchDiffSnapshotStore = .shared,
         openWindowWithValue: @escaping OpenWindowWithValue) {
        self.diffSnapshotStore = diffSnapshotStore
        self.openWindowWithValue = openWindowWithValue
    }

    func open(selection: WorkbenchDetailSelection) {
        guard let value = WorkbenchContextSceneValue(selection: selection, diffSnapshotStore: diffSnapshotStore) else {
            return
        }
        openWindowWithValue(WorkbenchContextWindowScene.id, value)
    }
}
```

并在 `WorkspaceState` 里把：

- `var contextWindowState: WorkbenchContextWindowState?`

改成：

- `var contextWindowRouter: WorkbenchContextWindowRouter?`

然后把 `showFileDetail`、`showGitDiffDetail`、`selectChangeProposal`、`openContextWindow` 全部改为走 `contextWindowRouter?.open(selection: ...)`。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkbenchContextWindowRouter.swift agentGui/Utilities/WorkspaceState.swift agentGui/Utilities/WorkbenchSceneServices.swift agentGuiTests/WorkbenchContextWindowRouterTests.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "refactor: route context windows through router"
```

### Task 3: 把上下文 scene 改为 data-driven WindowGroup，并把 context view 收缩为单实例渲染器

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchContextWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`

**Step 1: Write the failing test**

先用纯逻辑测试锁定“相同 selection 生成相同 scene value，供 `openWindow(value:)` 去前置已有窗口”，并补 `WorkspaceState.openContextWindow()` 在 `detailSelection != .none` 时会调用 router 的回归测试：

```swift
@Test func openContextWindowRoutesCurrentDetailSelection() {
    let recorder = ContextWindowRouteRecorder()
    let workspaceState = WorkspaceState()
    workspaceState.contextWindowRouter = WorkbenchContextWindowRouter(
        diffSnapshotStore: .inMemory,
        openWindowWithValue: recorder.openWindow
    )

    workspaceState.showFileDetail(URL(fileURLWithPath: "/tmp/repo/file.swift"))
    recorder.values.removeAll()

    workspaceState.openContextWindow()

    #expect(recorder.values == [.file(path: "/tmp/repo/file.swift")])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task3 -only-testing:agentGuiTests/WorkspaceStateTests -only-testing:agentGuiTests/WorkbenchContextWindowRouterTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，如果 `openContextWindow()` 仍然依赖旧 `hasTabs` / `requestPresentation` 逻辑。

**Step 3: Write minimal implementation**

将 `agentGuiApp.swift` 中：

```swift
Window("上下文", id: WorkbenchContextWindowScene.id) {
    WorkbenchContextWindowView()
}
```

替换为：

```swift
WindowGroup("上下文", id: WorkbenchContextWindowScene.id, for: WorkbenchContextSceneValue.self) { selection in
    WorkbenchContextWindowView(selection: selection)
}
```

同时重构 `WorkbenchContextWindowView`：

- 删除 `@Environment(WorkbenchContextWindowState.self)`
- 删除 `tabStrip`、`tabButton(_:)`、`closeOtherTabs`、`closeTabsToRight`、`selectNextTab`、`selectPreviousTab` 等 UI
- 保留内容分发，但输入改成单个 `WorkbenchContextSceneValue`
- 通过 diff snapshot store 把 `.gitDiff(title, snapshotID)` 还原为 `diffText`

`WorkbenchShellView` 中删除对 `contextWindowState.openRequestToken` 的监听，`WorkbenchConversationPane` 的按钮禁用逻辑改成只看 `workspaceState.detailSelection == .none`。

**Step 4: Run test to verify it passes**

先跑 task 3 focused tests，然后执行一次 compile-health fallback：

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task3-build CODE_SIGNING_ALLOWED=NO
```

Expected: tests PASS，app 编译通过。

**Step 5: Commit**

```bash
git add agentGui/agentGuiApp.swift agentGui/Views/Workbench/WorkbenchContextWindowView.swift agentGui/Views/Workbench/WorkbenchShellView.swift agentGui/Views/Workbench/WorkbenchConversationPane.swift agentGuiTests/WorkspaceStateTests.swift
git commit -m "refactor: move context scene to window group"
```

### Task 4: 配置 AppKit 原生 tabbing，并保持标题/represented URL 体验

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchContextWindowConfigurator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchContextWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchTitlePresentationTests.swift`

**Step 1: Write the failing test**

给标题展示补一个上下文实例测试，锁定文件与提案能映射到正确标题、副标题和 represented URL：

```swift
@Test func fileContextPresentationUsesFileNameAndPath() {
    let presentation = WorkbenchContextTitlePresentation.make(
        selection: .file(path: "/tmp/repo/File.swift")
    )

    #expect(presentation.title == "File.swift")
    #expect(presentation.subtitle == "/tmp/repo/File.swift")
    #expect(presentation.representedURL?.path == "/tmp/repo/File.swift")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task4 -only-testing:agentGuiTests/WorkbenchTitlePresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为上下文窗口尚未有单实例 presentation helper。

**Step 3: Write minimal implementation**

新增 `WorkbenchContextWindowConfigurator.swift`，并在上下文窗口视图中挂上它：

```swift
struct WorkbenchContextWindowConfigurator: NSViewRepresentable {
    let presentation: WorkbenchTitlePresentation

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configureWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configureWindow(for: nsView) }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.title = presentation.title
        window.subtitle = presentation.subtitle
        window.representedURL = presentation.representedURL
        window.tabbingIdentifier = "workbench-context"
        window.tabbingMode = .preferred
    }
}
```

并在 app 启动早期设置：

```swift
NSWindow.allowsAutomaticWindowTabbing = true
```

**Step 4: Run test to verify it passes**

同上测试命令，再跑一次 `build-for-testing`。

Expected: 标题测试通过，编译通过。

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchContextWindowConfigurator.swift agentGui/Views/Workbench/WorkbenchTitlePresentation.swift agentGui/Views/Workbench/WorkbenchContextWindowView.swift agentGui/agentGuiApp.swift agentGuiTests/WorkbenchTitlePresentationTests.swift
git commit -m "feat: configure native tabbing for context windows"
```

### Task 5: 清理命令系统与 legacy tab state

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandContext.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRequirement.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Modules/WindowCommands.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchSceneServices.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRouterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRegistryTests.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchContextWindowState.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchContextWindowStateTests.swift`

**Step 1: Write the failing test**

先把命令行为钉死到新的系统模型：

```swift
@Test func registryNoLongerExposesCustomContextTabCommands() {
    let ids = Set(AppCommandRegistry().descriptors.map(\.id))

    #expect(ids.contains(.openContextWindow))
    #expect(ids.contains(.selectNextContextTab) == false)
    #expect(ids.contains(.selectPreviousContextTab) == false)
}

@Test func openContextWindowRoutesThroughWorkspaceStateOnly() async {
    let workspaceState = WorkspaceState()
    let result = await AppCommandRouter().perform(
        .openContextWindow,
        in: .preview(workspaceState: workspaceState, workbenchState: WorkbenchState(), focusedScene: .workbench)
    )

    #expect(result == .performed)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-task5 -only-testing:agentGuiTests/AppCommandRouterTests -only-testing:agentGuiTests/AppCommandRegistryTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 registry 和 router 仍保留 custom context tab 命令以及 `contextWindowState` 依赖。

**Step 3: Write minimal implementation**

- 从 `AppCommandRegistry.defaultDescriptors` 移除 `.selectNextContextTab`、`.selectPreviousContextTab`
- 从 `WindowCommands` 菜单移除对应按钮
- 从 `AppCommandRouter` 删除这两个 `case`
- 从 `AppCommandRequirement` 删除 `.contextWindowTabs`
- 从 `AppCommandContext` 删除 `contextWindowState`
- 从 `WorkbenchSceneServices` 删除 `contextWindowState` 构建与注入
- 删除 `WorkbenchContextWindowState.swift`

确保 `openContextWindow` 仍然保留，作为“打开当前 detail 对应的 context window”命令。

**Step 4: Run test to verify it passes**

先跑 task 5 tests，再跑两套 focused regression：

1. `Command Platform Focused Tests`
2. `Focused workbench/context regression`

Expected: 全部 PASS。

**Step 5: Commit**

```bash
git add agentGui/AppCommands/Core/AppCommandContext.swift agentGui/AppCommands/Core/AppCommandRequirement.swift agentGui/AppCommands/Core/AppCommandRegistry.swift agentGui/AppCommands/Core/AppCommandRouter.swift agentGui/AppCommands/Modules/WindowCommands.swift agentGui/Utilities/WorkbenchSceneServices.swift agentGuiTests/AppCommandRouterTests.swift agentGuiTests/AppCommandRegistryTests.swift
git rm agentGui/Utilities/WorkbenchContextWindowState.swift agentGuiTests/WorkbenchContextWindowStateTests.swift
git commit -m "refactor: remove legacy context tab state"
```

### Task 6: 全量回归、文档同步与人工验收

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-25-context-window-windowgroup-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-25-context-window-windowgroup-implementation-plan.md`

**Step 1: Write the failing test**

这一步没有新增行为测试，改为先列出人工验收脚本，并在执行前确认前述自动化测试全绿。人工验收脚本本身要写入设计文档和实现计划末尾：

```text
1. 从工作区打开文件，确认打开一个 context window。
2. 再打开第二个文件，确认出现第二个 context window。
3. 使用 Window > Merge All Windows，确认系统原生 tab bar 接管。
4. 再次打开第一个文件，确认前置已有窗口/标签，而不是新建副本。
5. 打开 Git diff 和 change proposal，确认标题、内容、represented URL 正确。
```

**Step 2: Run test to verify it fails**

无单独失败测试；这一阶段以前五个任务全绿作为前置条件。

**Step 3: Write minimal implementation**

- 在设计文档末尾补一段“Implementation Status / Manual QA”
- 在本计划末尾补“Actual verification results”占位区，供执行会话填写

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-context-final CODE_SIGNING_ALLOWED=NO
```

Expected: 编译通过。随后执行人工验收脚本。

**Step 5: Commit**

```bash
git add docs/plans/2026-03-25-context-window-windowgroup-design.md docs/plans/2026-03-25-context-window-windowgroup-implementation-plan.md
git commit -m "docs: finalize context window migration plan"
```

## Actual Verification Results

本轮已完成以下非 UI 验证：

1. Focused context/window regression 通过：
    - `WorkbenchContextSceneValueTests`
    - `WorkbenchContextWindowRouterTests`
    - `WorkspaceStateTests`
    - `AppCommandRegistryTests`
    - `AppCommandRouterTests`
    - `WorkbenchTitlePresentationTests`
    - 汇总结果：34 tests in 6 suites passed，`TEST SUCCEEDED`
2. `Command Platform Focused Tests` task 通过：13 tests in 5 suites passed，`TEST SUCCEEDED`
3. 非 UI 全量编译验证通过：`xcodebuild build-for-testing ... CODE_SIGNING_ALLOWED=NO` 返回 `TEST BUILD SUCCEEDED`

本轮未运行任何 UI tests，符合“禁止运行 UI 测试”的执行约束。

## Manual QA Checklist

1. 从工作区打开一个文件，确认打开一个上下文窗口实例。
2. 再打开第二个文件，确认出现第二个上下文窗口实例。
3. 使用 Window > Merge All Windows，确认系统原生 window tab bar 接管。
4. 再次打开第一个文件，确认前置已有窗口或标签，而不是新建副本。
5. 打开 Git diff 和 change proposal，确认标题、副标题、represented URL 与内容路由正确。