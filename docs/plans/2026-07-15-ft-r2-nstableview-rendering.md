# FT-R2 实现计划：NSTableView 渲染 + 基础交互

**状态**：📋 待实施  
**基于设计**：[2026-07-15-filetree-rewrite-design.md](./2026-07-15-filetree-rewrite-design.md)  
**估计规模**：~500 行生产代码 + ~200 行测试 + 删除 ~680 行旧代码  
**前置条件**：FT-R0（数据模型）✅ + FT-R1（FSEvent Observer）✅ 已完成

---

## 背景与设计决策

### 为何从 NSOutlineView → NSTableView

VSCode `explorerViewer.ts` 中 `ExplorerDelegate.ITEM_HEIGHT = 22` 表明所有行固定高度，无需树控件的复杂布局。
`ExplorerDataSource.hasChildren()` 的展开状态与 DOM 树分离，外部维护。

Zed `project_panel.rs` 使用 `uniform_list`（等高扁平列表）———与 `NSTableView` 完全对应，
而非类似 NSOutlineView 的树视图。`update_visible_entries()` 重新计算 `visible_entries: Vec<VisibleEntriesForWorktree>`，
产生供列表控件直接消费的扁平快照，通过差量更新（如 `CollectionDifference`）驱动 UI。

因此本项目采用 `NSTableView`（AppKit 最高效扁平列表容器）：

1. **消除全量刷新**：`reloadData()` → `insertRows/removeRows` + `CollectionDifference`（FT-R4 阶段实施）
2. **展开状态外置**：由 `FileTreeStore.expandedIDs` 持有，不依赖 `NSOutlineView` 内部状态
3. **固定行高**：22pt（VSCode 标准），`usesStaticContents = true` 启用缓存优化
4. **缩进计算**：`depth * 16pt` spacer，与 Zed `indent_size`（默认 16px）一致

### 参考链接

- VSCode：[`explorerViewer.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts) — `ExplorerDelegate.ITEM_HEIGHT = 22`，`FilesRenderer.renderElement()`
- Zed：[`project_panel.rs`](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs) — `uniform_list`，`for_each_visible_entry()`，`render_entry()`，`FoldedAncestors`

---

## 前置状态确认

以下文件已存在，FT-R2 将直接消费：

| 文件 | 关键 API |
|------|---------|
| `agentGui/Models/FileEntry.swift` | `EntryID`, `FileEntry`, `LoadState` |
| `agentGui/Models/VisibleEntry.swift` | `VisibleEntry`, `FoldedAncestors` |
| `agentGui/Models/FileTreeSelection.swift` | `FileTreeSelection.add/toggle/setSingle` |
| `agentGui/Services/FileTreeStore.swift` | `setRoot`, `expandDirectory`, `collapseDirectory`, `computeVisibleEntries` |
| `agentGui/Utilities/FileIconSymbolResolver.swift` | `symbol(forFileName:) -> String` |

---

## 阶段分解

### Task 1｜FileTreeViewModel（绿灯优先）

**目标**：先写测试，定义 ViewModel 公共合约，再实现。

#### 1.1 创建测试文件

**新建** `agentGuiTests/FileTreeViewModelTests.swift`

```swift
// agentGuiTests/FileTreeViewModelTests.swift
import XCTest
@testable import agentGui

@MainActor
final class FileTreeViewModelTests: XCTestCase {

    // MARK: - 测试辅助

    func makeViewModel(entries: [URL: [ScannedEntry]] = [:]) -> FileTreeViewModel {
        let scanner = MockFileScanner()
        scanner.stubbedEntries = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.key.standardizedFileURL, $0.value) }
        )
        let store = FileTreeStore(scanner: scanner)
        return FileTreeViewModel(store: store)
    }

    // MARK: - setDirectory

    func testSetDirectory_populatesVisibleEntries() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: root.appendingPathComponent("src"), name: "src", isDirectory: true),
                ScannedEntry(url: root.appendingPathComponent("README.md"), name: "README.md", isDirectory: false),
            ]
        ])

        await vm.setDirectory(root)

        XCTAssertEqual(vm.visibleEntries.count, 2)
        let names = vm.visibleEntries.map(\.name)
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("README.md"))
    }

    func testSetDirectory_nil_clearsEntries() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: root.appendingPathComponent("a"), name: "a", isDirectory: false)]
        ])
        await vm.setDirectory(root)
        XCTAssertFalse(vm.visibleEntries.isEmpty)

        await vm.setDirectory(nil)
        XCTAssertTrue(vm.visibleEntries.isEmpty)
    }

    // MARK: - toggleDirectory

    func testToggleDirectory_expandsAndUpdates() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false)]
        ])

        await vm.setDirectory(root)
        XCTAssertEqual(vm.visibleEntries.count, 1)

        let srcID = EntryID(url: srcURL.standardizedFileURL)
        await vm.toggleDirectory(srcID)

        XCTAssertEqual(vm.visibleEntries.count, 2)
        XCTAssertTrue(vm.visibleEntries.map(\.name).contains("main.swift"))
    }

    func testToggleDirectory_collapsesAndUpdates() async throws {
        let root = URL(fileURLWithPath: "/tmp/project")
        let srcURL = root.appendingPathComponent("src")
        let vm = makeViewModel(entries: [
            root: [ScannedEntry(url: srcURL, name: "src", isDirectory: true)],
            srcURL: [ScannedEntry(url: srcURL.appendingPathComponent("main.swift"), name: "main.swift", isDirectory: false)]
        ])

        await vm.setDirectory(root)
        let srcID = EntryID(url: srcURL.standardizedFileURL)
        await vm.toggleDirectory(srcID)      // 展开
        XCTAssertEqual(vm.visibleEntries.count, 2)

        await vm.toggleDirectory(srcID)      // 折叠
        XCTAssertEqual(vm.visibleEntries.count, 1)
    }

    // MARK: - selectEntry

    func testSelectEntry_singleSelect() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let aURL = root.appendingPathComponent("a.txt")
        let bURL = root.appendingPathComponent("b.txt")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: aURL, name: "a.txt", isDirectory: false),
                ScannedEntry(url: bURL, name: "b.txt", isDirectory: false),
            ]
        ])
        await vm.setDirectory(root)
        let aID = EntryID(url: aURL.standardizedFileURL)

        vm.selectEntry(aID, modifier: .none)

        XCTAssertEqual(vm.selection.primary, aID)
        XCTAssertEqual(vm.selection.selected, [aID])
    }

    func testSelectEntry_cmdClickToggle() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let aURL = root.appendingPathComponent("a.txt")
        let bURL = root.appendingPathComponent("b.txt")
        let vm = makeViewModel(entries: [
            root: [
                ScannedEntry(url: aURL, name: "a.txt", isDirectory: false),
                ScannedEntry(url: bURL, name: "b.txt", isDirectory: false),
            ]
        ])
        await vm.setDirectory(root)
        let aID = EntryID(url: aURL.standardizedFileURL)
        let bID = EntryID(url: bURL.standardizedFileURL)

        vm.selectEntry(aID, modifier: .none)
        vm.selectEntry(bID, modifier: .add)

        XCTAssertEqual(vm.selection.selected.count, 2)
        XCTAssertTrue(vm.selection.selected.contains(aID))
        XCTAssertTrue(vm.selection.selected.contains(bID))

        // 再次 Cmd-click b → 取消选择
        vm.selectEntry(bID, modifier: .add)
        XCTAssertEqual(vm.selection.selected.count, 1)
        XCTAssertFalse(vm.selection.selected.contains(bID))
    }

    func testSelectEntry_shiftClickRange() async {
        let root = URL(fileURLWithPath: "/tmp/project")
        let urls = (0..<5).map { root.appendingPathComponent("\($0).txt") }
        let vm = makeViewModel(entries: [
            root: urls.map { ScannedEntry(url: $0, name: $0.lastPathComponent, isDirectory: false) }
        ])
        await vm.setDirectory(root)
        let ids = urls.map { EntryID(url: $0.standardizedFileURL) }

        vm.selectEntry(ids[0], modifier: .none)  // 选中第 0 项，设为 anchor
        vm.selectEntry(ids[2], modifier: .range) // Shift-click 第 2 项

        // 期望 0、1、2 全部被选中
        XCTAssertEqual(vm.selection.selected.count, 3)
        XCTAssertTrue(vm.selection.selected.contains(ids[0]))
        XCTAssertTrue(vm.selection.selected.contains(ids[1]))
        XCTAssertTrue(vm.selection.selected.contains(ids[2]))
    }
}
```

**运行空跑（编译失败符合预期）**：
```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

#### 1.2 实现 FileTreeViewModel

**新建** `agentGui/ViewModels/FileTreeViewModel.swift`

```swift
// agentGui/ViewModels/FileTreeViewModel.swift
import Foundation
import Observation

/// 调用者通过此枚举指定点击时的修饰键语义。
enum SelectionModifier {
    case none       // 普通单击：仅选中此项
    case add        // ⌘ 单击：追加/取消
    case range      // ⇧ 单击：从 anchor 到此项范围选择
}

/// FT-R2 ViewModel：桥接 FileTreeStore（actor 层）与 SwiftUI/NSTableView 展示层。
///
/// 对标 Zed project_panel.rs 中 `update_visible_entries()` → `visible_entries` 数据管道，
/// 以及 VSCode explorerViewer.ts 中 IAsyncDataTreeViewState 的分离原则：
/// 展开状态完全由外部（FileTreeStore）管理，UI 层只读取快照。
@Observable @MainActor
final class FileTreeViewModel {

    // MARK: - 公开状态（@Observable 自动追踪）

    /// 当前可见行的扁平列表，供 NSTableView 直接消费（Zed: visible_entries）
    private(set) var visibleEntries: [VisibleEntry] = []

    /// 当前选中状态（含多选和 anchor）
    var selection: FileTreeSelection = .init()

    // MARK: - 私有

    private let store: FileTreeStore

    // MARK: - 初始化

    init(store: FileTreeStore) {
        self.store = store
    }

    // MARK: - 目录操作

    /// 设置工作区根目录。传 nil 时清空所有状态。
    func setDirectory(_ url: URL?) async {
        guard let url else {
            visibleEntries = []
            selection = .init()
            return
        }
        await store.setRoot(url)
        visibleEntries = await store.computeVisibleEntries()
    }

    /// 切换目录展开/折叠状态，更新 visibleEntries 快照。
    ///
    /// 对标 Zed `toggle_expanded()`，展开状态保存于 store，UI 无状态。
    func toggleDirectory(_ id: EntryID) async {
        if await store.isExpanded(id) {
            await store.collapseDirectory(id)
        } else {
            try? await store.expandDirectory(id)
        }
        visibleEntries = await store.computeVisibleEntries()
    }

    // MARK: - 选择操作

    /// 处理行点击事件，根据修饰键更新 selection。
    ///
    /// 对标 VSCode explorerViewer.ts `onMouseClick()`，以及
    /// Zed project_panel.rs `on_click()` 中的 shift/secondary modifier 分支。
    func selectEntry(_ id: EntryID, modifier: SelectionModifier) {
        switch modifier {
        case .none:
            selection = FileTreeSelection(primary: id, selected: [id], anchor: id)

        case .add:
            // ⌘ 单击：已选中则取消，未选中则追加
            var sel = selection
            if sel.selected.contains(id) {
                sel.selected.remove(id)
                sel.primary = sel.selected.first
            } else {
                sel.selected.insert(id)
                sel.primary = id
            }
            sel.anchor = id
            selection = sel

        case .range:
            // ⇧ 单击：从 anchor 到 id 的连续范围，加入 selected
            guard let anchor = selection.anchor,
                  let anchorIdx = visibleEntries.firstIndex(where: { $0.id == anchor }),
                  let targetIdx = visibleEntries.firstIndex(where: { $0.id == id })
            else {
                selection = FileTreeSelection(primary: id, selected: [id], anchor: id)
                return
            }
            let lo = min(anchorIdx, targetIdx)
            let hi = max(anchorIdx, targetIdx)
            let rangeIDs = Set(visibleEntries[lo...hi].map(\.id))
            selection = FileTreeSelection(primary: id, selected: rangeIDs, anchor: selection.anchor ?? id)
        }
    }

    // MARK: - 内部刷新（FSEvent 触发）

    /// 仅重新计算可见列表，不改变展开状态。
    /// 由 FSEventObserver 回调时使用。
    func refreshVisibleEntries() async {
        visibleEntries = await store.computeVisibleEntries()
    }
}
```

> **依赖**：`FileTreeSelection` 需要 `init(primary:selected:anchor:)` 构造器。
> 检查现有 `FileTreeSelection.swift`，如缺少则添加此 init。

**运行测试（应全部通过）**：
```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Case|Suite|passed|failed)"
```

---

### Task 2｜FileTreeCellView（行渲染器）

**新建** `agentGui/Views/FileTree/FileTreeCellView.swift`

此文件实现 NSTableCellView 子类，排布 `[indent][disclosure][icon][name][git]`。
对标 Zed `render_entry()` 中的 `ListItem::indent_level(depth)` 缩进，
以及 VSCode `FilesRenderer.renderElement()` 中的行模板结构。

```swift
// agentGui/Views/FileTree/FileTreeCellView.swift
import AppKit

/// 文件树行单元格。
/// 布局：[indentSpacer] [disclosureButton?] [icon(14pt)] [nameLabel] [gitBadge?]
///
/// 行高固定 22pt（VSCode ExplorerDelegate.ITEM_HEIGHT = 22，
/// Zed project_panel 中 uniform_list item_height）。
final class FileTreeCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("fileTreeCell")

    // MARK: - 子视图

    private let indentSpacer = NSView()
    private let disclosureButton = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField()
    private let gitBadgeLabel = NSTextField()

    // MARK: - 回调

    /// 用户点击展开/折叠三角形时触发，传入对应 EntryID。
    var onToggleExpand: ((EntryID) -> Void)?

    // MARK: - 内部状态

    private var entryID: EntryID?

    // MARK: - 初始化

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    // MARK: - 构建布局

    private func buildLayout() {
        // indentSpacer：宽度由 depth 决定，高度撑满
        indentSpacer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indentSpacer)

        // disclosureButton：仅目录显示，SF Symbol chevron
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleTapped)
        addSubview(disclosureButton)

        // iconView：14pt 文件图标
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // nameLabel：只读文本
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        addSubview(nameLabel)

        // gitBadgeLabel：右侧 git 状态字符
        gitBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBadgeLabel.isBordered = false
        gitBadgeLabel.isEditable = false
        gitBadgeLabel.drawsBackground = false
        gitBadgeLabel.alignment = .right
        gitBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        addSubview(gitBadgeLabel)

        NSLayoutConstraint.activate([
            // 缩进占位（宽度通过 constraint.constant 动态设置）
            indentSpacer.leadingAnchor.constraint(equalTo: leadingAnchor),
            indentSpacer.topAnchor.constraint(equalTo: topAnchor),
            indentSpacer.bottomAnchor.constraint(equalTo: bottomAnchor),
            indentSpacer.widthAnchor.constraint(equalToConstant: 0),

            // 展开/折叠按钮：16×16
            disclosureButton.leadingAnchor.constraint(equalTo: indentSpacer.trailingAnchor),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            // 图标：14×14
            iconView.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            // 文件名 label
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // git badge：固定宽度，右对齐
            gitBadgeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            gitBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadgeLabel.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - 配置

    /// 根据 VisibleEntry 配置本行外观。
    ///
    /// - Parameters:
    ///   - entry: 当前行数据
    ///   - isSelected: 是否处于选中状态
    ///   - onToggle: 展开/折叠回调（在 Coordinator 中绑定）
    func configure(
        entry: VisibleEntry,
        isSelected: Bool,
        onToggle: @escaping (EntryID) -> Void
    ) {
        entryID = entry.id
        onToggleExpand = onToggle

        // 1. 缩进：depth * 16pt（与 Zed indent_size 一致）
        let indentConstraint = indentSpacer.constraints.first { $0.firstAttribute == .width }
        indentConstraint?.constant = CGFloat(entry.depth) * 16

        // 2. 展开/折叠按钮
        if entry.isDirectory {
            let symbolName = entry.isExpanded ? "chevron.down" : "chevron.right"
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            disclosureButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            disclosureButton.isHidden = false
        } else {
            disclosureButton.isHidden = true
        }

        // 3. 图标：复用 FileIconSymbolResolver
        let symbolName = FileIconSymbolResolver.symbol(forFileName: entry.name)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)

        // 4. 文件名
        nameLabel.stringValue = displayName(for: entry)
        nameLabel.textColor = isSelected ? .selectedMenuItemTextColor : .labelColor

        // 5. git badge（FT-R7 完整实现，此处占位）
        if let git = entry.gitSummary {
            gitBadgeLabel.isHidden = false
            gitBadgeLabel.stringValue = git.shortLabel
            gitBadgeLabel.textColor = git.nsColor
        } else {
            gitBadgeLabel.isHidden = true
        }
    }

    // MARK: - 折叠路径支持（FT-R5 预留）

    /// 返回显示名称。如有 foldedAncestors 则显示压缩路径，否则直接返回 name。
    private func displayName(for entry: VisibleEntry) -> String {
        if let folded = entry.foldedAncestors {
            let segments = folded.segments.map(\.name).joined(separator: " / ")
            return "\(segments) / \(entry.name)"
        }
        return entry.name
    }

    // MARK: - 事件处理

    @objc private func toggleTapped() {
        guard let id = entryID else { return }
        onToggleExpand?(id)
    }
}

// MARK: - GitSummary 显示扩展（使 GitSummary 可提供 UI 属性）

private extension GitSummary {
    /// 单字母 git 状态标记（对标 Zed git_status_indicator）
    var shortLabel: String {
        switch self {
        case .conflict: return "!"
        case .untracked: return "U"
        case .deleted:  return "D"
        case .modified: return "M"
        case .staged:   return "S"
        case .added:    return "A"
        default:        return ""
        }
    }

    var nsColor: NSColor {
        switch self {
        case .conflict: return .systemRed
        case .untracked, .added: return .systemGreen
        case .deleted:  return .systemRed
        case .modified: return .systemYellow
        case .staged:   return .systemBlue
        default:        return .secondaryLabelColor
        }
    }
}
```

> **注意**：`GitSummary` 的具体 case 名称需与 `agentGui/Models/` 中实际定义对齐。
> 若为枚举，直接 switch；若为结构体，根据字段判断。请在实施时核对。

---

### Task 3｜FileTreeTableRowView（行背景）

**新建** `agentGui/Views/FileTree/FileTreeTableRowView.swift`

```swift
// agentGui/Views/FileTree/FileTreeTableRowView.swift
import AppKit

/// 自定义行背景视图。
///
/// 对标 Zed render_entry() 中 `.bg(bg_color).hover(|s| s.bg(bg_hover_color))` 逻辑。
/// VSCode 通过 CSS 实现相同效果：`list-item-background-active`。
final class FileTreeTableRowView: NSTableRowView {

    // MARK: - 颜色常量（与 WorkspaceTreeRowContent 保持一致）

    /// 选中行：accent / 0.14
    private static let selectedColor = NSColor.controlAccentColor.withAlphaComponent(0.14)

    /// 悬停行：label / 0.07
    private static let hoverColor = NSColor.labelColor.withAlphaComponent(0.07)

    // MARK: - 状态

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    // MARK: - NSTrackingArea

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    // MARK: - 绘制

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            Self.selectedColor.setFill()
            dirtyRect.fill()
        } else if isHovered {
            Self.hoverColor.setFill()
            dirtyRect.fill()
        }
        // 未选中未悬停时不填充（继承父视图背景）
    }

    // 禁用系统默认的选中绘制，由 drawBackground 托管
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}
```

---

### Task 4｜FileTreeTableView（NSViewRepresentable 桥接）

**新建** `agentGui/Views/FileTree/FileTreeTableView.swift`

此文件是 FT-R2 的核心，实现 NSViewRepresentable 包装 NSTableView，
以及处理数据源、代理、键盘/鼠标选择事件的 Coordinator。

```swift
// agentGui/Views/FileTree/FileTreeTableView.swift
import SwiftUI
import AppKit

/// NSTableView NSViewRepresentable 桥接。
///
/// 架构对标：
/// - Zed `uniform_list("entries", item_count, ...)` — 扁平等高列表  
/// - VSCode `WorkbenchCompressibleAsyncDataTree` — 外部展开状态驱动
///
/// 行高固定 22pt，`usesStaticContents = true` 启用 NSTableView 缓存优化。
struct FileTreeTableView: NSViewRepresentable {

    // MARK: - 输入 props

    let entries: [VisibleEntry]
    let selection: FileTreeSelection

    // MARK: - 回调（单向数据流，ViewModel 持有真相）

    /// 用户点击行（选择变更）
    var onSelect: (EntryID, SelectionModifier) -> Void = { _, _ in }

    /// 用户点击展开/折叠三角形
    var onToggleExpand: (EntryID) -> Void = { _ in }

    /// 用户双击文件（打开文件）
    var onDoubleClick: (EntryID) -> Void = { _ in }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, selection: selection, onSelect: onSelect,
                    onToggleExpand: onToggleExpand, onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 22           // VSCode ExplorerDelegate.ITEM_HEIGHT = 22
        tableView.usesStaticContents = true
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none  // 由 FileTreeTableRowView 托管
        tableView.headerView = nil

        // 单列（Zed uniform_list 模型：单列扁平列表）
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        context.coordinator.tableView = tableView

        // 双击打开文件
        tableView.doubleAction = #selector(Coordinator.rowDoubleClicked)
        tableView.target = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onToggleExpand = onToggleExpand
        coordinator.onDoubleClick = onDoubleClick

        guard let tableView = coordinator.tableView else { return }

        let oldEntries = coordinator.entries

        // 判断是否需要全量刷新还是增量更新
        // FT-R4 阶段实现 CollectionDifference 增量；FT-R2 阶段使用全量刷新
        let structureChanged = oldEntries.map(\.id) != entries.map(\.id)
        coordinator.entries = entries

        if structureChanged {
            tableView.reloadData()
        }

        // 同步选中状态（避免反馈环）
        coordinator.syncSelectionToTable(tableView, selection: selection)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        var entries: [VisibleEntry]
        var selection: FileTreeSelection
        var onSelect: (EntryID, SelectionModifier) -> Void
        var onToggleExpand: (EntryID) -> Void
        var onDoubleClick: (EntryID) -> Void
        weak var tableView: NSTableView?

        /// 防止 tableViewSelectionDidChange 循环触发
        private var isSyncingSelection = false

        init(entries: [VisibleEntry], selection: FileTreeSelection,
             onSelect: @escaping (EntryID, SelectionModifier) -> Void,
             onToggleExpand: @escaping (EntryID) -> Void,
             onDoubleClick: @escaping (EntryID) -> Void) {
            self.entries = entries
            self.selection = selection
            self.onSelect = onSelect
            self.onToggleExpand = onToggleExpand
            self.onDoubleClick = onDoubleClick
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count else { return nil }
            let entry = entries[row]

            let cell = tableView.makeView(withIdentifier: FileTreeCellView.reuseIdentifier, owner: nil)
                as? FileTreeCellView ?? FileTreeCellView()
            cell.identifier = FileTreeCellView.reuseIdentifier

            let isSelected = selection.selected.contains(entry.id)
            cell.configure(entry: entry, isSelected: isSelected) { [weak self] id in
                // 展开/折叠不影响选中状态
                self?.onToggleExpand(id)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            FileTreeTableRowView()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            22  // 固定行高（VSCode standard = 22pt）
        }

        // MARK: 选择同步：Table → ViewModel

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView
            else { return }

            let selectedRows = tableView.selectedRowIndexes
            guard !selectedRows.isEmpty else { return }

            // 确定修饰键（通过当前 NSEvent 判断）
            let event = NSApp.currentEvent
            let modifier: SelectionModifier
            if event?.modifierFlags.contains(.command) == true {
                modifier = .add
            } else if event?.modifierFlags.contains(.shift) == true {
                modifier = .range
            } else {
                modifier = .none
            }

            // 取最后点击的行作为 primary
            let lastRow = tableView.clickedRow >= 0 ? tableView.clickedRow : selectedRows.last ?? 0
            guard lastRow < entries.count else { return }
            let primaryID = entries[lastRow].id
            onSelect(primaryID, modifier)
        }

        // MARK: 选择同步：ViewModel → Table

        func syncSelectionToTable(_ tableView: NSTableView, selection: FileTreeSelection) {
            self.selection = selection
            isSyncingSelection = true
            defer { isSyncingSelection = false }

            var indexSet = IndexSet()
            for (i, entry) in entries.enumerated() {
                if selection.selected.contains(entry.id) {
                    indexSet.insert(i)
                }
            }
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
        }

        // MARK: 双击

        @objc func rowDoubleClicked() {
            guard let tableView,
                  tableView.clickedRow >= 0,
                  tableView.clickedRow < entries.count
            else { return }
            let entry = entries[tableView.clickedRow]
            if !entry.isDirectory {
                onDoubleClick(entry.id)
            }
        }
    }
}
```

---

### Task 5｜FileTreeContainerView（SwiftUI 容器）

**新建** `agentGui/Views/FileTree/FileTreeContainerView.swift`

```swift
// agentGui/Views/FileTree/FileTreeContainerView.swift
import SwiftUI

/// 文件树 SwiftUI 容器视图。
/// 组合：[搜索占位] + [FileTreeTableView] + [状态栏]
///
/// 外部通过 `directory` 绑定根目录，`onOpenFile` 处理打开事件。
struct FileTreeContainerView: View {

    // MARK: - 外部输入

    var directory: URL?
    var onOpenFile: (EntryID) -> Void = { _ in }

    // MARK: - 内部状态

    @State private var viewModel: FileTreeViewModel

    // MARK: - 初始化

    init(directory: URL? = nil,
         store: FileTreeStore = FileTreeStore(),
         onOpenFile: @escaping (EntryID) -> Void = { _ in }) {
        self.directory = directory
        self.onOpenFile = onOpenFile
        _viewModel = State(initialValue: FileTreeViewModel(store: store))
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            // 主文件树
            FileTreeTableView(
                entries: viewModel.visibleEntries,
                selection: viewModel.selection,
                onSelect: { id, modifier in
                    viewModel.selectEntry(id, modifier: modifier)
                },
                onToggleExpand: { id in
                    Task { await viewModel.toggleDirectory(id) }
                },
                onDoubleClick: { id in
                    onOpenFile(id)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 状态栏（条目数）
            if !viewModel.visibleEntries.isEmpty {
                Divider()
                HStack {
                    Text("\(viewModel.visibleEntries.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
        .task(id: directory?.path) {
            await viewModel.setDirectory(directory)
        }
    }
}
```

---

### Task 6｜补全 FileTreeSelection.init

检查 `FileTreeSelection` 是否已有全参数 `init`。若无，补充：

```swift
// 在 agentGui/Models/FileTreeSelection.swift 中添加（如不存在）
extension FileTreeSelection {
    init(primary: EntryID?, selected: Set<EntryID>, anchor: EntryID?) {
        self.primary = primary
        self.selected = selected
        self.anchor = anchor
    }
}
```

---

### Task 7｜FileTreeStore.isExpanded 补充

检查 `FileTreeStore` 是否已暴露 `isExpanded(_ id: EntryID) -> Bool`。
若无，补充：

```swift
// 在 agentGui/Services/FileTreeStore.swift 中添加（如不存在）
func isExpanded(_ id: EntryID) -> Bool {
    expandedIDs.contains(id)
}
```

---

### Task 8｜删除旧 WorkspaceTree 文件

> ⚠️ **破坏性操作**：在删除前确认新文件树已接入主导航，且旧组件不再被引用。

```bash
# 确认无其他模块引用旧组件
grep -r "WorkspaceTreeOutlineView\|WorkspaceTreeView\|WorkspaceTreeRowContent" \
  agentGui/ --include="*.swift" | grep -v "WorkspaceTree/"
```

若引用为零：

```bash
git rm agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift
git rm agentGui/Views/WorkspaceTree/WorkspaceTreeView.swift
git rm agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift
```

> `WorkspaceTreeNativeCellView.swift`、`WorkspaceTreeKeyboard.swift`、
> `WorkspaceTreeInlineEdit.swift`、`WorkspaceTreeContextMenu.swift`
> 留待后续 FT-R6（键盘导航）、FT-R8（内联重命名）等阶段处理。

---

### Task 9｜添加测试目标到 Xcode scheme

在 `agentGui.xcodeproj` 中确认 `FileTreeViewModelTests` 已被测试 scheme 包含。
（通常通过 Xcode 产品方案勾选，或 `.xcscheme` XML 手动添加）

**运行完整 FT-R2 测试套件**：
```bash
xcodebuild test \
  -quiet \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r2-derived \
  -only-testing:agentGuiTests/FileTreeViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Case|Suite|passed|failed)|error:"
```

**期望结果**：
```
Test Suite 'FileTreeViewModelTests' started
Test Case 'testSetDirectory_populatesVisibleEntries' passed
Test Case 'testSetDirectory_nil_clearsEntries' passed
Test Case 'testToggleDirectory_expandsAndUpdates' passed
Test Case 'testToggleDirectory_collapsesAndUpdates' passed
Test Case 'testSelectEntry_singleSelect' passed
Test Case 'testSelectEntry_cmdClickToggle' passed
Test Case 'testSelectEntry_shiftClickRange' passed
Test Suite 'FileTreeViewModelTests' passed.
```

---

## 文件清单

### 新增（FT-R2）

| 文件 | 大致行数 | 说明 |
|------|---------|------|
| `agentGui/ViewModels/FileTreeViewModel.swift` | ~90 | ViewModel 核心 |
| `agentGui/Views/FileTree/FileTreeCellView.swift` | ~160 | NSTableCellView 行渲染 |
| `agentGui/Views/FileTree/FileTreeTableRowView.swift` | ~60 | NSTableRowView 背景 |
| `agentGui/Views/FileTree/FileTreeTableView.swift` | ~180 | NSViewRepresentable 桥接 |
| `agentGui/Views/FileTree/FileTreeContainerView.swift` | ~60 | SwiftUI 容器 |
| `agentGuiTests/FileTreeViewModelTests.swift` | ~180 | ViewModel 单元测试 |

### 删除（FT-R2）

| 文件 | 行数 |
|------|-----|
| `agentGui/Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` | ~550 |
| `agentGui/Views/WorkspaceTree/WorkspaceTreeView.swift` | ~20 |
| `agentGui/Views/WorkspaceTree/WorkspaceTreeRowContent.swift` | ~110 |

---

## 关键约束

1. **行高固定 22pt**（不可配置，VSCode 标准，Zed uniform_list 语义）
2. **usesStaticContents = true**：NSTableView 性能优化，不动态变更列定义
3. **选中状态由 ViewModel 持有**：NSTableView 内部选中状态仅作镜像，真相在 `FileTreeSelection`
4. **展开状态由 FileTreeStore 持有**：ViewModel 只读取快照，不缓存展开标志
5. **FT-R4 预留**：`updateNSView` 中的全量 `reloadData()` 将在 FT-R4 替换为 `CollectionDifference` 增量更新

---

## 后续阶段引用

- **FT-R3**（懒加载）：在 `toggleDirectory` 中处理 `LoadState.notLoaded` → loading spinner
- **FT-R4**（增量 diff）：将 `reloadData()` 替换为 `CollectionDifference` + `insertRows/removeRows`
- **FT-R5**（Auto-fold）：`FileTreeCellView.displayName()` 中已预留 `foldedAncestors` 分支
- **FT-R6**（键盘导航）：Coordinator 添加 `keyDown` 处理，使用 `WorkspaceTreeKeyboard.swift` 逻辑参考
- **FT-R7**（git badge 完整化）：完善 `GitSummary` 扩展，目录显示彩点
