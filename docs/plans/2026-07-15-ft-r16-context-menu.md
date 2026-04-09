# FT-R16：上下文菜单 + Reveal in Finder 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为新 `FileTreeTableView`（NSTableView）实现完整的右键上下文菜单，包含文件/文件夹的新建、重命名、删除、在访达中显示、复制相对路径、查看 Git Diff，以及对应的 `FileTreeViewModel` 操作方法，替换旧的 `WorkspaceTreeContextMenu`。

**Architecture:**
- `FileTreeContextMenu` — 纯值类型工厂（`enum` with `static func build(_:)`），参考 **Zed** `ContextMenu::build` 的 builder 模式：接受 `Config` 结构体（含 `targetEntry`、`selectedEntries`、所有回调闭包），返回 `NSMenu`；闭包通过 `NSMenuItem` + `HandlerInterceptor` 桥接。菜单项的显示/隐藏逻辑参考 **VSCode** `MenuId.ExplorerContext` 的 context key 条件：根节点不显示 Rename/Delete、多选时禁用 Rename、仅 Git 更改文件显示 Preview Diff。
- `FileTreeKeyboardTableView` — 已有的 NSTableView 子类，新增 `var contextMenuProvider: ((Int) -> NSMenu?)?` 属性，覆写 `menu(for event:)` 将点击行索引传给 Provider。
- `FileTreeTableView.Coordinator` — 新增 `onRevealInFinder`、`onCopyPath`、`onConfirmDelete`、`onPreviewDiff` 四个回调属性；实现 `buildContextMenu(forRow:)` 组装 Config → 调用 `FileTreeContextMenu.build`。
- `FileTreeViewModel` — 新增 `revealInFinder(ids:)`、`copyRelativePath(ids:)` 两个同步方法；新增 `beginDelete(ids:)` 用 `NSAlert` 确认后同步删除并刷新。

**Tech Stack:** Swift 6.0+, AppKit（`NSMenu`、`NSMenuItem`、`NSWorkspace`、`NSPasteboard`、`NSAlert`），XCTest

**参考来源：**

- **Zed** [`crates/project_panel/src/project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs) — `deploy_context_menu` 方法
  - `ContextMenu::build(cx, |menu, cx| { menu.action(...).when(condition, |menu| ...) })` — 链式 builder，`.when` 接受条件 bool 和配置闭包；本计划在 Swift 中用 `NSMenuItem` 数组 + `when` helper 函数模拟同效；
  - `is_root` 条件门控 Rename/Delete：`menu.when(!is_root, |m| m.action("Rename", ...).action("Delete", ...))` → Swift 对应 `if !isRoot { menu.addItem(...) }`；
  - `when(is_local, ...)` 门控 Reveal in Finder（SSH 远端不支持打开本地 Finder）→ 本计划始终显示（macOS 本地场景）；
  - `RevealInFinder` action → `cx.reveal_path(&path)` 最终调 `xdg-open` 或 macOS `NSWorkspace.activateFileViewerSelecting`。

- **VSCode** [`src/vs/workbench/contrib/files/browser/views/explorerView.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerView.ts) — context menu 构建模式
  - `onContextMenu(e: ITreeContextMenuEvent<ExplorerItem>)` 中：`contextMenuService.showContextMenu({ menuId: MenuId.ExplorerContext, contextKeyService, getActionsContext: () => stat })` — 以 context key service 驱动条件表达式；
  - Context key 门控逻辑（等效映射）：
    - `explorerResourceIsFolder` → 是否目录 → 控制图标和部分菜单项；
    - `explorerResourceIsRoot` / `explorerItemIsRoot` → 是否为工作区根目录 → 本计划用 `isRoot: Bool`（`entry.parentID == nil`）；
    - `resourceExtname` 等 → 文件类型特定动作（本计划暂不实现）；
    - Git context key （`isInGitRepository`、`isDirty`）→ 控制 `revealGitChange` 菜单项 → 本计划对应 `onPreviewDiff: (() -> Void)?`（非 nil 时才显示）；
  - `ClipboardService.writeText(resource.name)` for copy path → `NSPasteboard.general.setString(relativePath, forType: .string)`；
  - 多选（`multipleSelections.length > 1`）时禁用 Rename (`isEnabled = false`) → 本计划在 `Config` 中用 `selectedEntries.count != 1` 门控 Rename `isEnabled`。

- **旧代码** `agentGui/Views/WorkspaceTree/WorkspaceTreeContextMenu.swift`（将在 Task 6 删除）
  - `makeMenu(gitChange:target:action:)` — target/selector 绑定模式，所有动作共用单一 Selector；新实现改为每项独立闭包，消除 `action: WorkspaceTreeContextMenuAction.rawValue` 的字符串解析；
  - 旧菜单顺序（Diff → Reveal → CopyPath → New/Rename/Delete）→ 新菜单重排为 VSCode/Zed 标准顺序：New → Rename/Delete → 分隔符 → Reveal/CopyPath → 分隔符 → Diff。

- **设计文档** `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R16（菜单项表、估计行数）

---

## 前置条件

| Feature | 状态 | 说明 |
|---------|------|------|
| FT-R0 | ✅ | `EntryID`, `FileEntry`, `VisibleEntry`, `FileTreeStore` |
| FT-R2 | ✅ | `FileTreeTableView`, `FileTreeKeyboardTableView`, `FileTreeViewModel`, `FileTreeCellView` |
| FT-R8 | ✅ | `beginCreate`, `beginRename`, `commitEdit`, `cancelEdit` in ViewModel |
| `WorkspaceRevealService` | ✅ | `revealInFinder([URL])` via `NSWorkspace.activateFileViewerSelecting` |
| `WorkspaceFileTreeOperations` | ✅ | `deleteItem(at:)` |

当前实现缺口（FT-R16 需补齐）：

| 组件 | 现状 | 目标 |
|------|------|------|
| `FileTreeContextMenu.swift` | 不存在 | 新建：菜单工厂 + HandlerInterceptor |
| `FileTreeKeyboardTableView` | 无 `menu(for:)` | 新增 `contextMenuProvider` 属性 + `menu(for:)` 覆写 |
| `FileTreeTableView.Coordinator` | 无上下文菜单回调 | 新增 4 个回调 + `buildContextMenu(forRow:)` |
| `FileTreeTableView` struct | 无上下文菜单 props | 新增 4 个回调 props + updateNSView 联线 |
| `FileTreeViewModel` | 无 Reveal/CopyPath/Delete | 新增 3 个操作方法 |
| `FileTreeContainerView` | 无上下文菜单回调传递 | 联线 ViewModel 方法到 TableView |
| `WorkspaceTreeContextMenu.swift` | 旧实现 40 行 | Task 6 删除 |

---

## Task 1：`FileTreeContextMenu` 工厂 + HandlerInterceptor

**Files:**
- Create: `agentGui/Views/FileTree/FileTreeContextMenu.swift`
- Create: `agentGuiTests/FileTreeContextMenuTests.swift`

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeContextMenuTests.swift`：

```swift
// agentGuiTests/FileTreeContextMenuTests.swift
import XCTest
@testable import agentGui

final class FileTreeContextMenuTests: XCTestCase {

    // MARK: - 菜单结构验证（无需 UI，只检查 NSMenuItem 数量和 title）

    func testMenu_noSelection_showsNewItemsOnly() {
        var newFileCalled = false
        let config = FileTreeContextMenu.Config(
            targetEntry: nil,
            selectedEntries: [],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: { newFileCalled = true },
            onNewFolder: {},
            onRename: {},
            onDelete: {},
            onRevealInFinder: {},
            onCopyPath: {},
            onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        // 无选中时：新建文件、新建文件夹（2 项） + 分隔符 + Reveal + CopyPath（2 项）= 5 项
        XCTAssertEqual(menu.items.count, 5)
        XCTAssertEqual(menu.items[0].title, "新建文件")
        XCTAssertEqual(menu.items[1].title, "新建文件夹")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
    }

    func testMenu_singleFileSelection_showsAllItems() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("重命名"))
        XCTAssertTrue(titles.contains("删除"))
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("复制相对路径"))
    }

    func testMenu_multipleSelection_renameItemDisabled() {
        let entry1 = makeFileEntry(name: "A.swift")
        let entry2 = makeFileEntry(name: "B.swift")
        let config = FileTreeContextMenu.Config(
            targetEntry: entry1,
            selectedEntries: [entry1, entry2],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let renameItem = menu.items.first { $0.title == "重命名" }
        XCTAssertNotNil(renameItem)
        XCTAssertFalse(renameItem!.isEnabled)
    }

    func testMenu_rootDirectory_noRenameOrDelete() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeDirEntry(name: "project"),
            selectedEntries: [makeDirEntry(name: "project")],
            isRoot: true,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("重命名"))
        XCTAssertFalse(titles.contains("删除"))
    }

    func testMenu_gitChangedFile_showsPreviewDiff() {
        var diffCalled = false
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {},
            onPreviewDiff: { diffCalled = true }   // 非 nil → 显示该项
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("查看 Diff"))
    }

    func testMenu_noGitChange_noPreviewDiff() {
        let config = FileTreeContextMenu.Config(
            targetEntry: makeFileEntry(),
            selectedEntries: [makeFileEntry()],
            isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: {}, onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {},
            onPreviewDiff: nil    // nil → 不显示
        )
        let menu = FileTreeContextMenu.build(config)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("查看 Diff"))
    }

    func testMenu_newFileClosure_invoked() {
        var called = false
        let config = FileTreeContextMenu.Config(
            targetEntry: nil, selectedEntries: [], isRoot: false,
            rootURL: URL(fileURLWithPath: "/project"),
            onNewFile: { called = true },
            onNewFolder: {}, onRename: {}, onDelete: {},
            onRevealInFinder: {}, onCopyPath: {}, onPreviewDiff: nil
        )
        let menu = FileTreeContextMenu.build(config)
        // 直接触发第一项 action（HandlerInterceptor）
        let firstItem = menu.items[0]
        _ = firstItem.target?.perform(firstItem.action)
        XCTAssertTrue(called)
    }

    // MARK: - Helpers

    private func makeFileEntry(name: String = "File.swift") -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: false, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }

    private func makeDirEntry(name: String = "src") -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: true, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil, gitSummary: nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }
}
```

### Step 2：运行测试，确认编译失败（类型未定义）

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeContextMenuTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED"
```

预期：`error: cannot find type 'FileTreeContextMenu' in scope`（类型尚未定义）

### Step 3：创建 `FileTreeContextMenu.swift`

**新建** `agentGui/Views/FileTree/FileTreeContextMenu.swift`：

```swift
// agentGui/Views/FileTree/FileTreeContextMenu.swift
//
// 设计参考：
//   Zed   crates/project_panel/src/project_panel.rs — deploy_context_menu / ContextMenu::build
//   VSCode src/vs/workbench/contrib/files/browser/views/explorerView.ts — onContextMenu + MenuId.ExplorerContext context keys
//
// 菜单顺序（与 VSCode Explorer 对齐）：
//   新建文件 / 新建文件夹
//   [分隔符]
//   重命名（单选且非根）/ 删除（有选中且非根）
//   [分隔符]
//   在访达中显示 / 复制相对路径
//   [分隔符 + 查看 Diff（仅 Git 变更文件）]

import AppKit

enum FileTreeContextMenu {

    // MARK: - Config

    /// 构建上下文菜单所需的全部上下文，参考 Zed 的 deploy_context_menu 参数集合。
    struct Config {
        /// 右键点击的条目（nil = 在空白区域点击）
        let targetEntry: VisibleEntry?
        /// 当前选中的全部条目
        let selectedEntries: [VisibleEntry]
        /// 点击的条目是否为根目录（parentID == nil）
        /// Zed: !is_root 门控 Rename/Delete；VSCode: explorerItemIsRoot context key
        let isRoot: Bool
        /// 工作区根路径，用于计算相对路径
        let rootURL: URL?

        // ── 动作回调（对应 Zed ContextMenu::build 中的 .action(...)）
        /// 新建文件（⌘N）
        let onNewFile: () -> Void
        /// 新建文件夹（⌘⇧N）
        let onNewFolder: () -> Void
        /// 重命名（Return）— 仅单选且非根时启用
        let onRename: () -> Void
        /// 删除（⌫）— 有选中且非根时显示
        let onDelete: () -> Void
        /// 在访达中显示（⌘R）
        let onRevealInFinder: () -> Void
        /// 复制相对路径（⌥⌘C）
        let onCopyPath: () -> Void
        /// 查看 Git Diff — nil 表示目标文件无 Git 变更，不显示此项
        /// VSCode: isDirty / isInGitRepository context key 门控
        let onPreviewDiff: (() -> Void)?
    }

    // MARK: - 菜单工厂

    /// 根据 Config 构建 NSMenu。
    /// 纯函数：不保存任何状态，不访问全局，便于单元测试。
    static func build(_ config: Config) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Zed: 始终显示新建（参考 ContextMenu::build 中 .action("New File", ...) 无任何条件）
        menu.addItem(item(title: "新建文件",       key: "n",  modifiers: .command,  action: config.onNewFile))
        menu.addItem(item(title: "新建文件夹",     key: "N",  modifiers: [.command, .shift], action: config.onNewFolder))

        let hasSelection = !config.selectedEntries.isEmpty
        let isSingleSelection = config.selectedEntries.count == 1

        // ── Zed: .when(!is_root, ...) 门控 Rename/Delete
        if hasSelection && !config.isRoot {
            menu.addItem(.separator())

            // Rename — VSCode: 多选时 isEnabled = false（explorerItemIsHighlighted = false）
            let renameItem = item(title: "重命名", key: "\r", modifiers: [], action: config.onRename)
            renameItem.isEnabled = isSingleSelection   // 多选时禁用，单选时启用
            menu.addItem(renameItem)

            menu.addItem(item(title: "删除", key: String(UnicodeScalar(NSDeleteCharacter)!), modifiers: [], action: config.onDelete))
        }

        // ── 访达 + 路径（不受 isRoot 限制，参考 VSCode 中根目录也能 Reveal in Finder）
        menu.addItem(.separator())
        menu.addItem(item(title: "在访达中显示",   key: "r",  modifiers: .command,  action: config.onRevealInFinder))
        menu.addItem(item(title: "复制相对路径",   key: "c",  modifiers: [.command, .option], action: config.onCopyPath))

        // ── Git Diff — VSCode: isDirty context key；Zed: entry.git_status.is_some()
        if let onDiff = config.onPreviewDiff {
            menu.addItem(.separator())
            menu.addItem(item(title: "查看 Diff", key: "", modifiers: [], action: onDiff))
        }

        return menu
    }

    // MARK: - NSMenuItem 辅助（闭包桥接）

    /// 创建带闭包的 NSMenuItem。
    /// 使用 HandlerInterceptor 作为 target，避免 target/action 字符串分发的脆弱性。
    private static func item(
        title: String,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        action closure: @escaping () -> Void
    ) -> NSMenuItem {
        let interceptor = HandlerInterceptor(closure)
        let item = NSMenuItem(
            title: title,
            action: #selector(HandlerInterceptor.invoke),
            keyEquivalent: key
        )
        item.keyEquivalentModifierMask = modifiers
        item.target = interceptor
        item.representedObject = interceptor   // 强持有，防 ARC 回收
        item.isEnabled = true
        return item
    }
}

// MARK: - HandlerInterceptor（私有桥接）

/// NSMenuItem target 的闭包桥接，替代旧代码 `target: AnyObject, action: Selector` 模式。
/// 每个 NSMenuItem 持有自己的 HandlerInterceptor 实例，与菜单生命周期绑定。
private final class HandlerInterceptor: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func invoke() {
        closure()
    }
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeContextMenuTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期输出：`Test Suite 'FileTreeContextMenuTests' passed`（6 tests）

### Step 5：Commit

```bash
git add agentGui/Views/FileTree/FileTreeContextMenu.swift \
        agentGuiTests/FileTreeContextMenuTests.swift
git commit -m "feat(FT-R16): add FileTreeContextMenu factory with HandlerInterceptor bridge

- Config struct mirrors Zed deploy_context_menu params (isRoot, selectedEntries, onPreviewDiff?)
- Conditional items: Rename/Delete only when !isRoot && hasSelection; Rename disabled on multi-select
- Git Diff item only when onPreviewDiff != nil (VSCode isDirty context key equivalent)
- HandlerInterceptor bridges NSMenuItem to Swift closures, replaces target/action string dispatch
- 6 unit tests covering menu structure and closure invocation"
```

---

## Task 2：`FileTreeKeyboardTableView` 覆写 `menu(for:)` + Coordinator 集成

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`
  - `FileTreeKeyboardTableView` — 新增 `contextMenuProvider` + `menu(for:)` 覆写
  - `FileTreeTableView` struct — 新增 4 个回调 props
  - `Coordinator` — 新增 4 个回调属性 + `buildContextMenu(forRow:)` + 安装 provider

### Step 1：编写预期失败的集成测试

**新增**到 `agentGuiTests/FileTreeContextMenuTests.swift`：

```swift
// MARK: - Coordinator 集成测试（无需显示窗口）

final class FileTreeContextMenuCoordinatorTests: XCTestCase {

    func testBuildContextMenu_forFileRow_containsExpectedItems() {
        let entry = makeVisibleFile(name: "App.swift", hasGitChange: false)
        let coordinator = makeCoordinator(entries: [entry])
        let menu = coordinator.buildContextMenu(forRow: 0)
        XCTAssertNotNil(menu)
        let titles = menu!.items.map(\.title)
        XCTAssertTrue(titles.contains("新建文件"))
        XCTAssertTrue(titles.contains("在访达中显示"))
        XCTAssertTrue(titles.contains("复制相对路径"))
    }

    func testBuildContextMenu_forOutOfBoundsRow_returnsNil() {
        let coordinator = makeCoordinator(entries: [])
        let menu = coordinator.buildContextMenu(forRow: 5)
        XCTAssertNil(menu)
    }

    func testBuildContextMenu_forGitChangedFile_showsDiff() {
        let entry = makeVisibleFile(name: "Changed.swift", hasGitChange: true)
        let coordinator = makeCoordinator(entries: [entry])
        let menu = coordinator.buildContextMenu(forRow: 0)
        let titles = menu!.items.map(\.title)
        XCTAssertTrue(titles.contains("查看 Diff"))
    }

    func testBuildContextMenu_forNegativeRow_returnsNil() {
        let coordinator = makeCoordinator(entries: [makeVisibleFile()])
        XCTAssertNil(coordinator.buildContextMenu(forRow: -1))
    }

    // MARK: - Helpers

    private func makeVisibleFile(name: String = "File.swift", hasGitChange: Bool = false) -> VisibleEntry {
        VisibleEntry(
            id: EntryID(url: URL(fileURLWithPath: "/project/\(name)")),
            name: name, isDirectory: false, depth: 1,
            isExpanded: false, loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: hasGitChange ? .modified : nil,
            diagnosticSeverity: nil, isIgnored: false
        )
    }

    private func makeCoordinator(entries: [VisibleEntry]) -> FileTreeTableView.Coordinator {
        let c = FileTreeTableView.Coordinator(
            entries: entries,
            selection: .init(),
            onSelect: { _, _ in }, onToggleExpand: { _ in }, onDoubleClick: { _ in }
        )
        c.rootURL = URL(fileURLWithPath: "/project")
        return c
    }
}
```

### Step 2：运行测试，确认失败（方法未定义）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeContextMenuCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED"
```

预期：`error: value of type 'FileTreeTableView.Coordinator' has no member 'buildContextMenu'`

### Step 3：修改 `FileTreeTableView.swift`

**在 `FileTreeKeyboardTableView` 类中新增：**

```swift
// FileTreeTableView.swift 中 FileTreeKeyboardTableView 类体内追加

/// 右键菜单提供者：传入点击行索引，返回 NSMenu（nil = 不显示菜单）。
/// 由 Coordinator 在 makeNSView 时设置。
var contextMenuProvider: ((Int) -> NSMenu?)?

/// 覆写 NSResponder.menu(for:)，将点击位置转换为行索引后委托给 provider。
/// 参考 Zed project_panel: right_button_down → deploy_context_menu(position, entry_id)
override func menu(for event: NSEvent) -> NSMenu? {
    let localPoint = convert(event.locationInWindow, from: nil)
    let row = self.row(at: localPoint)

    // 若点击了一个未选中的行，先将该行设为选中
    // VSCode: 右键时若点击未选中行，先切换选中（explorerView onContextMenu 中 revealInExplorer）
    if row >= 0, !selectedRowIndexes.contains(row) {
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    return contextMenuProvider?(row)
}
```

**在 `FileTreeTableView` struct 新增 4 个回调 props（紧跟现有 `onRenameSelected` 之后）：**

```swift
// 在 "var onRenameSelected: () -> Void = {}" 之后追加

/// ⌘R — 在访达中显示选中的条目
var onRevealInFinder: ([EntryID]) -> Void = { _ in }

/// ⌥⌘C — 复制相对路径到剪贴板
var onCopyPath: ([EntryID]) -> Void = { _ in }

/// ⌫（via context menu）— 删除选中条目（含确认对话框）
var onConfirmDelete: (Set<EntryID>) -> Void = { _ in }

/// 查看 Git Diff（仅对有 Git 状态的文件显示）
var onPreviewDiff: ((EntryID) -> Void)? = nil
```

**在 `makeCoordinator` 中传入新回调：**

```swift
func makeCoordinator() -> Coordinator {
    Coordinator(entries: entries, selection: selection,
                onSelect: onSelect, onToggleExpand: onToggleExpand,
                onDoubleClick: onDoubleClick, onUnfoldSegment: onUnfoldSegment,
                onCommitEdit: onCommitEdit, onCancelEdit: onCancelEdit,
                onNewFile: onNewFile, onNewFolder: onNewFolder,
                onRenameSelected: onRenameSelected,
                onRevealInFinder: onRevealInFinder,
                onCopyPath: onCopyPath,
                onConfirmDelete: onConfirmDelete,
                onPreviewDiff: onPreviewDiff,
                onMoveEntries: onMoveEntries, onCopyEntries: onCopyEntries,
                onImportExternalFiles: onImportExternalFiles,
                onExpandDirectory: onExpandDirectory)
}
```

**在 `makeNSView` 中安装 contextMenuProvider（紧跟 `tableView.target = context.coordinator` 之后）：**

```swift
// 安装上下文菜单 provider
tableView.contextMenuProvider = { [weak c = context.coordinator] row in
    c?.buildContextMenu(forRow: row)
}
```

**在 `updateNSView` 中同步新回调（紧跟 `coordinator.onRenameSelected = onRenameSelected` 之后）：**

```swift
coordinator.onRevealInFinder = onRevealInFinder
coordinator.onCopyPath = onCopyPath
coordinator.onConfirmDelete = onConfirmDelete
coordinator.onPreviewDiff = onPreviewDiff
```

**在 `Coordinator` 中新增属性和 `buildContextMenu`：**

```swift
// Coordinator 属性区，紧跟 onRenameSelected 之后
var onRevealInFinder: ([EntryID]) -> Void
var onCopyPath: ([EntryID]) -> Void
var onConfirmDelete: (Set<EntryID>) -> Void
var rootURL: URL? = nil          // 由 updateNSView 赋值
var onPreviewDiff: ((EntryID) -> Void)? = nil
```

在 `Coordinator` init 中添加对应参数和赋值。

**新增 `buildContextMenu(forRow:)` 方法（Coordinator 体内）：**

```swift
/// 根据行索引构建右键菜单。
/// 参考 Zed deploy_context_menu(position, entry_id) 的实现路径。
func buildContextMenu(forRow row: Int) -> NSMenu? {
    guard row >= 0, row < entries.count else { return nil }

    let entry = entries[row]

    // 确定选中集合（若点击行已在选中集合中，使用全部选中行；否则只用点击行）
    let selectedIDs = selection.selected.contains(entry.id)
        ? Array(selection.selected)
        : [entry.id]
    let selectedEntries = selectedIDs.compactMap { id in entries.first { $0.id == id } }

    // Zed: is_root = entry.parentID == nil（工作区根目录不展示 Rename/Delete）
    let isRoot = entry.id == entries.first(where: { $0.depth == 0 })?.id

    // VSCode: isDirty context key — onPreviewDiff 非 nil 当且仅当目标文件有 Git 变更
    let previewDiffCallback: (() -> Void)? = entry.gitSummary != nil
        ? { [weak self] in self?.onPreviewDiff?(entry.id) }
        : nil

    let config = FileTreeContextMenu.Config(
        targetEntry: entry,
        selectedEntries: selectedEntries,
        isRoot: isRoot,
        rootURL: rootURL,
        onNewFile: { [weak self] in self?.onNewFile() },
        onNewFolder: { [weak self] in self?.onNewFolder() },
        onRename: { [weak self] in self?.onRenameSelected() },
        onDelete: { [weak self] in
            guard let self else { return }
            self.onConfirmDelete(Set(selectedIDs))
        },
        onRevealInFinder: { [weak self] in
            guard let self else { return }
            self.onRevealInFinder(selectedIDs)
        },
        onCopyPath: { [weak self] in
            guard let self else { return }
            self.onCopyPath(selectedIDs)
        },
        onPreviewDiff: previewDiffCallback
    )

    return FileTreeContextMenu.build(config)
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeContextMenuTests \
  -only-testing:agentGuiTests/FileTreeContextMenuCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：全部 10 个测试通过

### Step 5：Commit

```bash
git add agentGui/Views/FileTree/FileTreeTableView.swift \
        agentGuiTests/FileTreeContextMenuTests.swift
git commit -m "feat(FT-R16): wire context menu into FileTreeKeyboardTableView + Coordinator

- Override menu(for:) in FileTreeKeyboardTableView, delegate to contextMenuProvider
- Auto-select right-clicked row if not already selected (VSCode explorerView behavior)
- Add onRevealInFinder/onCopyPath/onConfirmDelete/onPreviewDiff props to FileTreeTableView
- Add buildContextMenu(forRow:) to Coordinator: isRoot detection, git status → onPreviewDiff
- 4 coordinator integration tests"
```

---

## Task 3：`FileTreeViewModel` — `revealInFinder` + `copyRelativePath`

**Files:**
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`
- Create: `agentGuiTests/FileTreeViewModelRevealCopyTests.swift`

### Step 1：编写预期失败的测试

**新建** `agentGuiTests/FileTreeViewModelRevealCopyTests.swift`：

```swift
// agentGuiTests/FileTreeViewModelRevealCopyTests.swift
import XCTest
@testable import agentGui

@MainActor
final class FileTreeViewModelRevealCopyTests: XCTestCase {

    // MARK: - copyRelativePath

    func testCopyRelativePath_singleFile_writesRelPath() async {
        let vm = makeViewModel()
        await vm.setDirectory(URL(fileURLWithPath: "/project"))
        let id = EntryID(url: URL(fileURLWithPath: "/project/src/App.swift"))

        vm.copyRelativePath(ids: [id])

        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "src/App.swift")
    }

    func testCopyRelativePath_rootURLNil_writesAbsPath() async {
        let vm = makeViewModel()
        // rootURL 未设置时 fallback 到绝对路径
        let id = EntryID(url: URL(fileURLWithPath: "/project/src/App.swift"))
        vm.copyRelativePath(ids: [id])
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "/project/src/App.swift")
    }

    func testCopyRelativePath_multipleFiles_writesNewlineSeparated() async {
        let vm = makeViewModel()
        await vm.setDirectory(URL(fileURLWithPath: "/project"))
        let ids = [
            EntryID(url: URL(fileURLWithPath: "/project/A.swift")),
            EntryID(url: URL(fileURLWithPath: "/project/B.swift"))
        ]
        vm.copyRelativePath(ids: ids)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "A.swift\nB.swift")
    }

    // MARK: - revealInFinder（仅验证不崩溃，无法 assert NSWorkspace 行为）

    func testRevealInFinder_doesNotCrash() {
        let vm = makeViewModel()
        let id = EntryID(url: URL(fileURLWithPath: "/project/App.swift"))
        // 此路径不存在，NSWorkspace 会静默失败；只需确保不崩溃
        XCTAssertNoThrow(vm.revealInFinder(ids: [id]))
    }

    // MARK: - Helpers

    private func makeViewModel() -> FileTreeViewModel {
        FileTreeViewModel(store: FileTreeStore(scanner: MockFileScanner()))
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeViewModelRevealCopyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:"
```

预期：`error: value of type 'FileTreeViewModel' has no member 'copyRelativePath'`

### Step 3：在 `FileTreeViewModel` 中新增方法

在 `agentGui/ViewModels/FileTreeViewModel.swift` 中，在现有 DnD 操作方法之后追加：

```swift
// MARK: - FT-R16 上下文菜单操作

/// 在访达中显示指定条目。
/// 复用 WorkspaceRevealService（参考设计文档 §FT-R16 "复用现有"）。
/// Zed: RevealInFinder action → cx.reveal_path(&path)
/// VSCode: explorerService.select(resource, true) → revealInExplorer
func revealInFinder(ids: [EntryID]) {
    let urls = ids.map(\.url)
    WorkspaceRevealService().revealInFinder(urls)
}

/// 复制相对路径到系统剪贴板。
/// VSCode: ClipboardService.writeText(relPath) in copyRelativeFilePath command
/// 多文件：换行分隔（与 VSCode 行为一致）。
func copyRelativePath(ids: [EntryID]) {
    let paths: [String] = ids.map { id in
        if let root = rootURL {
            let rootPath = root.standardizedFileURL.path
            let filePath = id.url.standardizedFileURL.path
            if filePath.hasPrefix(rootPath + "/") {
                return String(filePath.dropFirst(rootPath.count + 1))
            }
        }
        return id.url.path
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
}
```

> **注意**：`rootURL` 已在 `FileTreeViewModel` 中存在（`setDirectory` 时赋值）；`WorkspaceRevealService` 直接实例化（无状态）。

### Step 4：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeViewModelRevealCopyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|error:"
```

预期：4 个测试全部通过

### Step 5：Commit

```bash
git add agentGui/ViewModels/FileTreeViewModel.swift \
        agentGuiTests/FileTreeViewModelRevealCopyTests.swift
git commit -m "feat(FT-R16): add revealInFinder + copyRelativePath to FileTreeViewModel

- revealInFinder: delegates to WorkspaceRevealService.revealInFinder([URL])
- copyRelativePath: strips rootURL prefix; multi-select joins with newline (VSCode behavior)
- Falls back to absolute path when rootURL is nil
- 4 unit tests"
```

---

## Task 4：`FileTreeViewModel` — `beginDelete`（基础删除确认）

**Files:**
- Modify: `agentGui/ViewModels/FileTreeViewModel.swift`
- Modify: `agentGuiTests/FileTreeViewModelRevealCopyTests.swift`（追加）

> **说明**：FT-R15 会将 `beginDelete` 升级为带 SwiftUI Alert 的完整删除流程；本任务实现 AppKit `NSAlert` 版本，保证 FT-R16 菜单的"删除"能工作。

### Step 1：追加测试到 `FileTreeViewModelRevealCopyTests.swift`

```swift
// 追加到 FileTreeViewModelRevealCopyTests

// MARK: - beginDelete

func testBeginDelete_emptyIds_doesNothing() async {
    let vm = makeViewModel()
    // 空集合不显示 Alert，不崩溃
    XCTAssertNoThrow(vm.beginDelete(ids: []))
}
```

> `NSAlert` 是模态的，无法在单元测试中断言。此 Task 仅保证编译和空集合的非崩溃行为；实际弹窗逻辑需手动验收（见 Task 5 验收步骤）。

### Step 2：在 `FileTreeViewModel` 中新增 `beginDelete`

```swift
/// 弹出 NSAlert 确认后删除指定条目，并刷新受影响父目录。
/// FT-R15 将用带 SwiftUI Alert 的 PendingDeletion 模型替换此实现。
func beginDelete(ids: Set<EntryID>) {
    guard !ids.isEmpty else { return }

    let names = ids.compactMap { visibleEntries.first { $0.id == $0.id }?.name ?? $0.url.lastPathComponent }
    let displayNames = names.prefix(3).joined(separator: "、")
    let suffix = names.count > 3 ? " 等 \(names.count) 项" : ""

    let alert = NSAlert()
    alert.messageText = "删除 \(displayNames)\(suffix)？"
    alert.informativeText = "此操作无法撤销。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    Task {
        var parentURLs = Set<URL>()
        for id in ids {
            let url = id.url
            parentURLs.insert(url.deletingLastPathComponent())
            try? WorkspaceFileTreeOperations.deleteItem(at: url)
        }
        // 刷新受影响的父目录
        for parentURL in parentURLs {
            await store.refreshDirectory(EntryID(url: parentURL))
        }
        let newEntries = await store.computeVisibleEntries()
        self.visibleEntries = newEntries
        fixSelectionAfterChange(removedIDs: ids)
    }
}

/// 删除/移动后修复选择状态（移除已不存在的条目）。
private func fixSelectionAfterChange(removedIDs: Set<EntryID>) {
    selection.selected.subtract(removedIDs)
    if let primary = selection.primary, removedIDs.contains(primary) {
        // 选中被删除项之后的第一个可见项（VSCode 行为）
        if let idx = visibleEntries.firstIndex(where: { $0.id == primary }),
           idx + 1 < visibleEntries.count {
            selection.primary = visibleEntries[idx + 1].id
        } else {
            selection.primary = visibleEntries.last?.id
        }
    }
}
```

### Step 3：运行测试，确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -only-testing:agentGuiTests/FileTreeViewModelRevealCopyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|error:"
```

### Step 4：Commit

```bash
git add agentGui/ViewModels/FileTreeViewModel.swift \
        agentGuiTests/FileTreeViewModelRevealCopyTests.swift
git commit -m "feat(FT-R16): add beginDelete to FileTreeViewModel (NSAlert confirmation)

- NSAlert modal confirms before calling WorkspaceFileTreeOperations.deleteItem
- Refreshes affected parent directories after deletion
- fixSelectionAfterChange: removes deleted entries from selection, picks next visible row
- FT-R15 will replace with SwiftUI PendingDeletion Alert model"
```

---

## Task 5：`FileTreeContainerView` 联线 + 手动验收

**Files:**
- Modify: `agentGui/Views/FileTree/FileTreeContainerView.swift`
- Modify: `agentGui/Views/FileTree/FileTreeTableView.swift`（Coordinator 更新路径）

### Step 1：检查 `FileTreeContainerView` 当前状态

在 `FileTreeContainerView.swift` 中，找到 `FileTreeTableView(...)` 的构造调用，确认当前已有的回调联线（`onNewFile`、`onNewFolder`、`onRenameSelected`）。

### Step 2：追加 4 个新回调

在 `FileTreeContainerView.swift` 的 `FileTreeTableView(...)` 构造中追加：

```swift
// 紧跟现有 onRenameSelected: { viewModel.beginRename() } 之后

.onRevealInFinder { ids in
    viewModel.revealInFinder(ids: ids)
}
.onCopyPath { ids in
    viewModel.copyRelativePath(ids: ids)
}
.onConfirmDelete { ids in
    viewModel.beginDelete(ids: ids)
}
.onPreviewDiff { id in
    // TODO: 接入 Git Diff 预览视图（FT-R17 或现有 PreviewDiffService）
    NSLog("[FT-R16] previewDiff not yet connected: \(id.url.lastPathComponent)")
}
```

> `onPreviewDiff` 先用 `NSLog` 占位；实际连线由 FT-R17（Git Diff 面板）完成。

### Step 3：在 `updateNSView` 中同步 `rootURL`

在 `FileTreeTableView.swift` 的 `Coordinator` 中，`rootURL` 需要被同步。在 `updateNSView` 中追加：

```swift
coordinator.rootURL = /* 从 ViewModel 或环境获取 */ viewModel?.rootURL
```

> 注意：若 `FileTreeContainerView` 不直接持有 `FileTreeViewModel`，需通过参数或 `@Environment` 传递 `rootURL`。检查当前 `FileTreeContainerView` 的 ViewModel 持有方式；多数情况下 `viewModel.rootURL` 即可直接访问。

### Step 4：构建 + 启动应用手动验收

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

手动验收清单（在运行的应用中操作）：

| 操作 | 预期结果 |
|------|---------|
| 右键文件 | 菜单出现：新建文件、新建文件夹、重命名、删除、在访达中显示、复制相对路径 |
| 右键根目录 | 无"重命名"和"删除" |
| 右键多选 | "重命名"显示但为灰色（disabled） |
| 点击"在访达中显示" | Finder 打开并高亮对应文件 |
| 点击"复制相对路径" | 粘贴到文本编辑器可见相对路径 |
| 点击"删除" | 弹出 NSAlert，确认后文件消失，刷新列表 |
| 点击"删除" → 取消 | 文件不变 |
| 右键 Git 变更文件 | 显示"查看 Diff" |
| 右键未变更文件 | 不显示"查看 Diff" |
| 在空白区域右键 | 菜单出现：新建文件、新建文件夹（无 Rename/Delete） |

### Step 5：Commit

```bash
git add agentGui/Views/FileTree/FileTreeContainerView.swift \
        agentGui/Views/FileTree/FileTreeTableView.swift
git commit -m "feat(FT-R16): wire context menu callbacks in FileTreeContainerView

- Connect onRevealInFinder/onCopyPath/onConfirmDelete/onPreviewDiff to ViewModel
- onPreviewDiff: NSLog placeholder, to be connected in FT-R17
- Sync rootURL to Coordinator in updateNSView"
```

---

## Task 6：删除旧文件 `WorkspaceTreeContextMenu.swift`

### Step 1：确认旧文件不再被引用

```bash
grep -r "WorkspaceTreeContextMenu" /Volumes/T7/文稿/Projects/agentGui/agentGui \
  --include="*.swift" -l
```

预期：无输出（旧引用已清理）或只有 `WorkspaceTreeContextMenu.swift` 自身。

若有引用，先修改引用处改用新的 `FileTreeContextMenu.Config` + callback 机制。

### Step 2：删除旧文件

```bash
rm /Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspaceTree/WorkspaceTreeContextMenu.swift
```

### Step 3：从 Xcode project.pbxproj 移除文件引用

```bash
# 检查 pbxproj 中是否还有引用（Xcode 未自动清理时）
grep "WorkspaceTreeContextMenu" /Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj
```

若有残留：在 Xcode 中打开项目 → 删除项目导航栏中的红色（missing file）引用，选择"Remove Reference"。

或手动从 pbxproj 删除：
```bash
# 找到文件 UUID
grep -n "WorkspaceTreeContextMenu" agentGui.xcodeproj/project.pbxproj
# 在 pbxproj 中删除对应的 PBXBuildFile 和 PBXFileReference 条目
```

### Step 4：重新构建，确认无错误

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** BUILD SUCCEEDED **`

### Step 5：Commit

```bash
git add -A
git commit -m "chore(FT-R16): remove WorkspaceTreeContextMenu.swift

Old target/selector pattern replaced by FileTreeContextMenu.Config + closure callbacks.
Ref: docs/plans/2026-07-15-filetree-rewrite-design.md §七、删除清单"
```

---

## Task 7：全量测试运行 + 最终 Commit

### Step 1：运行所有 FT-R16 相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r16-final \
  -only-testing:agentGuiTests/FileTreeContextMenuTests \
  -only-testing:agentGuiTests/FileTreeContextMenuCoordinatorTests \
  -only-testing:agentGuiTests/FileTreeViewModelRevealCopyTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

预期：共 ~14 个测试，全部 passed。

### Step 2：回归测试（FT-R2、FT-R8、FT-R9 不能回退）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r16-regression \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  -only-testing:agentGuiTests/FileTreeInlineEditTests \
  -only-testing:agentGuiTests/FileTreeDropValidatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

预期：全部通过，无回归。

### Step 3：最终 Commit

```bash
git add -A
git commit -m "feat(FT-R16): context menu + Reveal in Finder — complete

Summary:
- FileTreeContextMenu.swift: pure factory, Zed-style builder config, HandlerInterceptor bridge
- FileTreeKeyboardTableView.menu(for:): right-click row selection + contextMenuProvider callback
- FileTreeTableView: 4 new callback props (revealInFinder/copyPath/confirmDelete/previewDiff)
- FileTreeViewModel: revealInFinder, copyRelativePath (relative path + multi newline), beginDelete (NSAlert + fixSelectionAfterChange)
- FileTreeContainerView: all callbacks connected; onPreviewDiff placeholder for FT-R17
- Deleted WorkspaceTreeContextMenu.swift (40 lines)
- 14 unit tests

Context key mapping (VSCode → Swift):
  explorerItemIsRoot         → isRoot: Bool (entry.depth == 0)
  isDirty / isGitRepository  → entry.gitSummary != nil → show Preview Diff
  multipleSelections         → selectedEntries.count > 1 → Rename disabled

Ref: docs/plans/2026-07-15-filetree-rewrite-design.md §FT-R16"
```

---

## 汇总：新增/修改/删除文件清单

| 操作 | 文件 | 行数（估计） |
|------|------|-------------|
| 新建 | `agentGui/Views/FileTree/FileTreeContextMenu.swift` | ~100 |
| 修改 | `agentGui/Views/FileTree/FileTreeTableView.swift` | +80（新增 4 props + Coordinator 方法 + menu override） |
| 修改 | `agentGui/ViewModels/FileTreeViewModel.swift` | +60（revealInFinder / copyRelativePath / beginDelete / fixSelectionAfterChange） |
| 修改 | `agentGui/Views/FileTree/FileTreeContainerView.swift` | +15（4 个回调联线） |
| 删除 | `agentGui/Views/WorkspaceTree/WorkspaceTreeContextMenu.swift` | -40 |
| 新建 | `agentGuiTests/FileTreeContextMenuTests.swift` | ~130 |
| 新建 | `agentGuiTests/FileTreeViewModelRevealCopyTests.swift` | ~80 |

**净变化**：+~395 行产品代码，+~210 行测试，-40 行旧代码

---

## 已知局限 / 后续工作

| 项目 | 状态 | 后续 |
|------|------|------|
| `onPreviewDiff` 实现 | NSLog 占位 | FT-R17 或 Git Diff 面板接入 |
| `beginDelete` 使用 `NSAlert` 模态 | 可用 | FT-R15 升级为 SwiftUI `PendingDeletion` Alert + Undo |
| 键盘快捷键（⌫ 删除、⌘R Reveal） | 未实现 | FT-R11 键盘导航中补充 |
| "在终端中打开"菜单项 | 未包含 | Zed 有此功能；可在后续版本添加 |
