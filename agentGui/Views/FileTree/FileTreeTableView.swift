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

    /// 用户点击折叠路径分段时触发，由 FileTreeViewModel.unfoldDirectory 处理。
    var onUnfoldSegment: ((EntryID) -> Void)? = nil

    /// 用户双击文件（打开文件）
    var onDoubleClick: (EntryID) -> Void = { _ in }

    // MARK: - FT-R9 DnD 回调

    /// 移动条目到目标目录
    var onMoveEntries: ([EntryID], EntryID) -> Void = { _, _ in }

    /// 复制条目到目标目录（Option+拖动）
    var onCopyEntries: ([EntryID], EntryID) -> Void = { _, _ in }

    /// 外部文件拖入
    var onImportExternalFiles: ([URL], EntryID) -> Void = { _, _ in }

    /// 悬停展开目录
    var onExpandDirectory: (EntryID) -> Void = { _ in }

    /// 当前 store 快照（供验证器使用）
    var storeSnapshot: FileTreeStoreSnapshot? = nil

    // MARK: - 内联编辑 props（FT-R8）

    /// 当前内联编辑会话（nil = 非编辑态）。传入 Cell 决定渲染模式。
    var inlineEditSession: InlineEditSession? = nil

    /// 用户在内联文本框按 Return（或失焦时草稿合法）→ 携带已 trim 的草稿名称。
    var onCommitEdit: (String) -> Void = { _ in }

    /// 用户按 Escape 或失焦时草稿为空/非法 → 取消。
    var onCancelEdit: () -> Void = {}

    /// Cmd+N — 新建文件。
    var onNewFile: () -> Void = {}

    /// Cmd+Shift+N — 新建文件夹。
    var onNewFolder: () -> Void = {}

    /// Return（非编辑态，已选中一个条目）→ 重命名。
    var onRenameSelected: () -> Void = {}

    // MARK: - FT-R16 上下文菜单回调

    /// ⌘R — 在访达中显示选中的条目
    var onRevealInFinder: ([EntryID]) -> Void = { _ in }

    /// ⌥⌘C — 复制相对路径到剪贴板
    var onCopyPath: ([EntryID]) -> Void = { _ in }

    /// ⌫（via context menu）— 删除选中条目（含确认对话框）
    var onConfirmDelete: (Set<EntryID>) -> Void = { _ in }

    /// 查看 Git Diff（仅对有 Git 状态的文件显示）
    var onPreviewDiff: ((EntryID) -> Void)? = nil

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, selection: selection, onSelect: onSelect,
                    onToggleExpand: onToggleExpand, onDoubleClick: onDoubleClick,
                    onUnfoldSegment: onUnfoldSegment,
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

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = FileTreeKeyboardTableView()
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
        context.coordinator.keyboardTableView = tableView

        // FT-R9: 注册拖放类型
        context.coordinator.registerDragTypes(for: tableView)

        // 单击：目录切换展开/文件打开（对标 VSCode ExplorerView._onMouseClick + Zed ProjectPanel.on_click）
        tableView.action = #selector(Coordinator.rowClicked)
        // 双击：文件打开（保留）
        tableView.doubleAction = #selector(Coordinator.rowDoubleClicked)
        tableView.target = context.coordinator

        // FT-R16: 安装上下文菜单 provider
        tableView.contextMenuProvider = { [weak c = context.coordinator] row in
            c?.buildContextMenu(forRow: row)
        }

        // 表级悬停控制器（替代 per-row NSTrackingArea，避免滚动时多行 hover）
        context.coordinator.hoverController.install(on: tableView)

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
        coordinator.onUnfoldSegment = onUnfoldSegment
        coordinator.inlineEditSession = inlineEditSession
        coordinator.onCommitEdit = onCommitEdit
        coordinator.onCancelEdit = onCancelEdit
        coordinator.onNewFile = onNewFile
        coordinator.onNewFolder = onNewFolder
        coordinator.onRenameSelected = onRenameSelected
        // FT-R16: 上下文菜单回调
        coordinator.onRevealInFinder = onRevealInFinder
        coordinator.onCopyPath = onCopyPath
        coordinator.onConfirmDelete = onConfirmDelete
        coordinator.onPreviewDiff = onPreviewDiff
        // FT-R9: DnD 回调
        coordinator.onMoveEntries = onMoveEntries
        coordinator.onCopyEntries = onCopyEntries
        coordinator.onImportExternalFiles = onImportExternalFiles
        coordinator.onExpandDirectory = onExpandDirectory
        coordinator.storeSnapshot = storeSnapshot

        // 同步键盘状态
        coordinator.keyboardTableView?.isInlineEditing = inlineEditSession != nil
        coordinator.keyboardTableView?.onNewFile = onNewFile
        coordinator.keyboardTableView?.onNewFolder = onNewFolder
        coordinator.keyboardTableView?.onRenameSelected = onRenameSelected
        coordinator.keyboardTableView?.onCancelEdit = onCancelEdit

        guard let tableView = coordinator.tableView else { return }

        let oldEntries = coordinator.entries

        // FT-R4: 增量 diff 更新，替代全量 reloadData()
        // 参考 VSCode List.splice() 和 Zed uniform_list cx.notify() 触发的行级更新
        coordinator.entries = entries
        coordinator.selection = selection  // 先更新 selection，applyDiff 末尾的 syncSelectionToTable 会使用新值
        coordinator.applyDiff(from: oldEntries, to: entries, tableView: tableView)

        // selection 由 applyDiff 末尾的 syncSelectionToTable 处理，无需重复调用
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        var entries: [VisibleEntry]
        var selection: FileTreeSelection
        var onSelect: (EntryID, SelectionModifier) -> Void
        var onToggleExpand: (EntryID) -> Void
        var onDoubleClick: (EntryID) -> Void
        var onUnfoldSegment: ((EntryID) -> Void)?
        // FT-R8: 内联编辑
        var inlineEditSession: InlineEditSession? = nil
        var onCommitEdit: (String) -> Void
        var onCancelEdit: () -> Void
        var onNewFile: () -> Void
        var onNewFolder: () -> Void
        var onRenameSelected: () -> Void
        // FT-R16: 上下文菜单
        var onRevealInFinder: ([EntryID]) -> Void
        var onCopyPath: ([EntryID]) -> Void
        var onConfirmDelete: (Set<EntryID>) -> Void
        var rootURL: URL? = nil
        var onPreviewDiff: ((EntryID) -> Void)? = nil
        weak var tableView: NSTableView?
        weak var keyboardTableView: FileTreeKeyboardTableView?

        /// 表级悬停控制器（替代 per-row NSTrackingArea）
        let hoverController = FileTreeHoverController()

        // FT-R9: DnD
        var onMoveEntries: ([EntryID], EntryID) -> Void
        var onCopyEntries: ([EntryID], EntryID) -> Void
        var onImportExternalFiles: ([URL], EntryID) -> Void
        var onExpandDirectory: (EntryID) -> Void
        var storeSnapshot: FileTreeStoreSnapshot? = nil
        /// 当前拖拽会话状态（nil = 非拖拽态）
        var dragState: FileTreeDragState? = nil

        /// 防止 tableViewSelectionDidChange 循环触发
        private var isSyncingSelection = false

        init(entries: [VisibleEntry], selection: FileTreeSelection,
             onSelect: @escaping (EntryID, SelectionModifier) -> Void,
             onToggleExpand: @escaping (EntryID) -> Void,
             onDoubleClick: @escaping (EntryID) -> Void,
             onUnfoldSegment: ((EntryID) -> Void)? = nil,
             onCommitEdit: @escaping (String) -> Void = { _ in },
             onCancelEdit: @escaping () -> Void = {},
             onNewFile: @escaping () -> Void = {},
             onNewFolder: @escaping () -> Void = {},
             onRenameSelected: @escaping () -> Void = {},
             onRevealInFinder: @escaping ([EntryID]) -> Void = { _ in },
             onCopyPath: @escaping ([EntryID]) -> Void = { _ in },
             onConfirmDelete: @escaping (Set<EntryID>) -> Void = { _ in },
             onPreviewDiff: ((EntryID) -> Void)? = nil,
             onMoveEntries: @escaping ([EntryID], EntryID) -> Void = { _, _ in },
             onCopyEntries: @escaping ([EntryID], EntryID) -> Void = { _, _ in },
             onImportExternalFiles: @escaping ([URL], EntryID) -> Void = { _, _ in },
             onExpandDirectory: @escaping (EntryID) -> Void = { _ in }) {
            self.entries = entries
            self.selection = selection
            self.onSelect = onSelect
            self.onToggleExpand = onToggleExpand
            self.onDoubleClick = onDoubleClick
            self.onUnfoldSegment = onUnfoldSegment
            self.onCommitEdit = onCommitEdit
            self.onCancelEdit = onCancelEdit
            self.onNewFile = onNewFile
            self.onNewFolder = onNewFolder
            self.onRenameSelected = onRenameSelected
            self.onRevealInFinder = onRevealInFinder
            self.onCopyPath = onCopyPath
            self.onConfirmDelete = onConfirmDelete
            self.onPreviewDiff = onPreviewDiff
            self.onMoveEntries = onMoveEntries
            self.onCopyEntries = onCopyEntries
            self.onImportExternalFiles = onImportExternalFiles
            self.onExpandDirectory = onExpandDirectory
        }

        // MARK: - FT-R16 上下文菜单构建

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

            // Zed: is_root = entry is at depth 0（工作区根目录不展示 Rename/Delete）
            let isRoot = entry.depth == 0

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
            cell.configure(
                entry: entry,
                isSelected: isSelected,
                inlineEditSession: inlineEditSession,
                onToggle: { [weak self] id in self?.onToggleExpand(id) },
                onUnfoldSegment: { [weak self] id in self?.onUnfoldSegment?(id) },
                onCommitEdit: { [weak self] draft in self?.onCommitEdit(draft) },
                onCancelEdit: { [weak self] in self?.onCancelEdit() },
                onValidate: { [weak self] text in
                    guard let self, let session = inlineEditSession else { return nil }
                    // 实时校验：传空 siblings，让 Session 只检查格式；完整校验在 commitEdit 中
                    return session.validateDraftName(siblingNames: [])
                }
            )
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

        // MARK: 增量 diff 更新（FT-R4）

        /// 将 VisibleEntry 列表变更应用到 NSTableView。
        ///
        /// 算法参考：
        /// - VSCode `List.splice()` — 先做 trait splice（selection 索引偏移），再做 DOM insert/remove
        /// - Zed `uniform_list` — 框架内部以 ID diff 驱动 row-level 更新
        ///
        /// 本实现：
        /// 1. 用 `FileTreeDiff.compute` 计算结构/内容变更
        /// 2. 结构变更：`beginUpdates` → `removeRows/insertRows` → `endUpdates`
        /// 3. 内容变更：`reloadData(forRowIndexes:columnIndexes:)`
        /// 4. 降级条件：`shouldFullReload == true` → `reloadData()`
        func applyDiff(
            from old: [VisibleEntry],
            to new: [VisibleEntry],
            tableView: NSTableView
        ) {
            let diff = FileTreeDiff.compute(from: old, to: new)

            if diff.shouldFullReload {
                tableView.reloadData()
                return
            }

            // 结构变更：使用 beginUpdates/endUpdates 包装，产生动画
            if !diff.removals.isEmpty || !diff.insertions.isEmpty {
                tableView.beginUpdates()
                if !diff.removals.isEmpty {
                    tableView.removeRows(
                        at: diff.removals,
                        withAnimation: .effectFade
                    )
                }
                if !diff.insertions.isEmpty {
                    tableView.insertRows(
                        at: diff.insertions,
                        withAnimation: .effectFade
                    )
                }
                tableView.endUpdates()
            }

            // 内容变更（无结构变化时）：原地刷新，不触发动画
            if !diff.contentReloads.isEmpty {
                tableView.reloadData(
                    forRowIndexes: diff.contentReloads,
                    columnIndexes: IndexSet(integer: 0)
                )
            }

            // 恢复选中状态（insert/remove 可能导致行索引偏移）
            syncSelectionToTable(tableView, selection: selection)
        }

        // MARK: 单击（目录切换展开 / 文件打开）

        /// 单击行为（对标 VSCode ExplorerView._onMouseClick / Zed ProjectPanel.on_click）：
        /// - 目录：切换展开/折叠（整行可点，不仅限 disclosure 三角形）
        /// - 文件：触发 onDoubleClick（打开/预览）
        /// 选择变更已由 `tableViewSelectionDidChange` 处理，此处只补充交互语义。
        @objc func rowClicked() {
            guard let tableView,
                  tableView.clickedRow >= 0,
                  tableView.clickedRow < entries.count
            else { return }
            let entry = entries[tableView.clickedRow]
            if entry.isDirectory {
                // 目录：单击切换展开/折叠
                onToggleExpand(entry.id)
            } else {
                // 文件：单击打开（对标 VSCode 的 preview 模式，即 single-click open）
                onDoubleClick(entry.id)
            }
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

// MARK: - FT-R9 FileTreeDragState

/// 拖动过程中的瞬态状态，存在 Coordinator（@MainActor）中。
/// 生命周期：draggingSession willBegin 创建，endedAt 销毁。
final class FileTreeDragState {
    /// 当前鼠标悬停行（-1 = 无）
    var hoveredRow: Int = -1

    /// 500ms 悬停展开计时器（光标移出时取消）
    var hoverExpandWork: DispatchWorkItem?

    /// 面板边缘自动滚动计时器（光标离开边缘区域时取消）
    var edgeScrollWork: DispatchWorkItem?

    /// 拖拽源行索引集合
    var dragSourceRows: IndexSet = []

    /// 当前 Auto-fold 段命中（若有）
    var foldedSegmentTarget: (entryID: EntryID, segmentIndex: Int)?

    /// 是否按住 Option（Copy 模式）
    var isCopyMode: Bool = false

    deinit {
        hoverExpandWork?.cancel()
        edgeScrollWork?.cancel()
    }

    func cancelHoverExpand() {
        hoverExpandWork?.cancel()
        hoverExpandWork = nil
    }

    func cancelEdgeScroll() {
        edgeScrollWork?.cancel()
        edgeScrollWork = nil
    }
}

// MARK: - FT-R9 DnD Coordinator 扩展（Pasteboard 注册 + 拖拽源）

extension FileTreeTableView.Coordinator {

    /// 内部拖放使用的 pasteboard 类型标识
    static let internalDragType = NSPasteboard.PasteboardType(
        rawValue: "com.feint.agentGui.fileTreeEntry"
    )

    /// 注册支持的拖放类型（在 makeNSView 中调用一次）
    func registerDragTypes(for tableView: NSTableView) {
        tableView.registerForDraggedTypes([
            Self.internalDragType,  // 内部路径
            .fileURL,               // 外部文件可直接粘贴为 URL
        ])
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
    }

    // MARK: NSTableViewDataSource — 拖拽源

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < entries.count else { return nil }
        let entry = entries[row]

        // 不允许拖拽占位行（FT-R8 内联编辑状态）
        guard !entry.isEditPlaceholder else { return nil }

        let item = NSPasteboardItem()
        // 写入 EntryID（以 URL path 表示）
        item.setString(entry.id.url.path, forType: Self.internalDragType)
        // 同时写 fileURL，让外部应用（如 Finder）可接收
        item.setData(
            entry.id.url.dataRepresentation,
            forType: .fileURL
        )
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        dragState = FileTreeDragState()
        dragState?.dragSourceRows = rowIndexes
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragState?.cancelHoverExpand()
        dragState?.cancelEdgeScroll()
        dragState = nil
        // 清除高亮
        tableView.setDropRow(-1, dropOperation: .on)
    }

    func tableView(
        _ tableView: NSTableView,
        updateDraggingItemsForDrag draggingInfo: any NSDraggingInfo
    ) {
        let isOption = NSEvent.modifierFlags.contains(.option)
        if dragState?.isCopyMode != isOption {
            dragState?.isCopyMode = isOption
            tableView.setNeedsDisplay(tableView.bounds)
        }
    }

    // MARK: - 内部辅助

    /// 从 pasteboard 读取内部拖拽的 EntryID 列表
    func extractSourceIDs(from pasteboard: NSPasteboard) -> [EntryID] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            guard let path = item.string(forType: Self.internalDragType) else { return nil }
            return EntryID(url: URL(fileURLWithPath: path))
        }
    }

    /// 给定 proposedRow，返回对应的 VisibleEntry（-1 或越界时返回 nil）
    func resolvedDropEntry(row: Int) -> VisibleEntry? {
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    /// 当 targetEntry 是文件时，将目标行重定向到其父目录所在行
    func resolvedDropRow(row: Int, targetEntry: VisibleEntry?) -> Int {
        guard let entry = targetEntry else { return -1 }
        if entry.isDirectory { return row }
        // 文件：高亮其父目录行
        let parentURL = entry.id.url.deletingLastPathComponent().standardizedFileURL
        let parentID = EntryID(url: parentURL)
        if let parentRow = entries.firstIndex(where: { $0.id == parentID }) {
            return parentRow
        }
        return row
    }
}

// MARK: - FT-R9 DnD Coordinator 扩展（validateDrop + acceptDrop）

extension FileTreeTableView.Coordinator {

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        let isInternal = pasteboard.types?.contains(Self.internalDragType) == true

        // ── 外部文件拖入路径 ──────────────────────────────────────
        if !isInternal {
            if let externalURLs = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
            ) as? [URL], !externalURLs.isEmpty {
                let targetEntry = resolvedDropEntry(row: row)
                let targetRow = resolvedDropRow(row: row, targetEntry: targetEntry)
                tableView.setDropRow(targetRow, dropOperation: .on)
                return .copy
            }
            return []
        }

        // ── 内部拖放路径 ──────────────────────────────────────────
        let sourceIDs = extractSourceIDs(from: pasteboard)
        guard !sourceIDs.isEmpty else { return [] }

        let targetEntry = resolvedDropEntry(row: row)
        let isCopy = (dragState?.isCopyMode ?? false) || NSEvent.modifierFlags.contains(.option)

        // 检查是否命中了 auto-fold 段（精确目标）
        var foldHit: (EntryID, Int)? = nil
        if let targetEntry, let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileTreeCellView {
            let localPoint = cell.convert(tableView.convert(info.draggingLocation, from: nil), from: tableView)
            if let hit = cell.hitTestFoldedSegment(at: localPoint) {
                foldHit = (hit.entryID, hit.segmentIndex)
            }
        }
        dragState?.foldedSegmentTarget = foldHit.map { (entryID: $0.0, segmentIndex: $0.1) }

        // 确定目标 EntryID
        let targetID: EntryID?
        if let (foldedEntryID, _) = foldHit {
            targetID = foldedEntryID
        } else if let entry = targetEntry {
            if entry.isDirectory {
                targetID = entry.id
            } else {
                // 文件 → 解析到父目录
                let parentURL = entry.id.url.deletingLastPathComponent().standardizedFileURL
                targetID = EntryID(url: parentURL)
            }
        } else {
            targetID = nil  // 背景区域 → 后续处理
        }

        guard let snapshot = storeSnapshot else { return [] }

        // 背景区域：目标为根（取第一个条目的根祖先若有；否则不允许）
        if let tid = targetID {
            guard FileTreeDropValidator.validate(
                sourceIDs: sourceIDs,
                destinationID: tid,
                snapshot: snapshot,
                isCopy: isCopy
            ) != nil else { return [] }

            let targetRow = resolvedDropRow(row: row, targetEntry: targetEntry)
            tableView.setDropRow(targetRow, dropOperation: .on)

            // 悬停 500ms 自动展开（目录且未展开）
            if let entry = targetEntry, entry.isDirectory, !entry.isExpanded {
                if dragState?.hoveredRow != targetRow {
                    dragState?.hoveredRow = targetRow
                    scheduleHoverExpand(entryID: entry.id, after: 0.5)
                }
            } else if dragState?.hoveredRow != targetRow {
                dragState?.hoveredRow = targetRow
                dragState?.cancelHoverExpand()
            }
        } else {
            dragState?.cancelHoverExpand()
        }

        // 面板边缘自动滚动
        updateEdgeScroll(for: info.draggingLocation, in: tableView)

        return isCopy ? .copy : .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        dragState?.cancelHoverExpand()
        dragState?.cancelEdgeScroll()
        tableView.setDropRow(-1, dropOperation: .on)

        let pasteboard = info.draggingPasteboard
        let isInternal = pasteboard.types?.contains(Self.internalDragType) == true

        // ── 外部文件拖入 ──────────────────────────────────────────
        if !isInternal {
            guard let externalURLs = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
            ) as? [URL], !externalURLs.isEmpty else { return false }

            let targetEntry = resolvedDropEntry(row: row)
            let targetID: EntryID
            if let entry = targetEntry {
                if entry.isDirectory {
                    targetID = entry.id
                } else {
                    let parentURL = entry.id.url.deletingLastPathComponent().standardizedFileURL
                    targetID = EntryID(url: parentURL)
                }
            } else {
                // 背景区域：取根目录
                guard let rootEntry = entries.first else { return false }
                let rootURL = rootEntry.id.url.deletingLastPathComponent().standardizedFileURL
                targetID = EntryID(url: rootURL)
            }
            onImportExternalFiles(externalURLs, targetID)
            return true
        }

        // ── 内部拖放 ──────────────────────────────────────────────
        let sourceIDs = extractSourceIDs(from: pasteboard)
        guard !sourceIDs.isEmpty else { return false }

        let targetEntry = resolvedDropEntry(row: row)
        let targetID: EntryID
        if let entry = targetEntry {
            if entry.isDirectory {
                targetID = entry.id
            } else {
                let parentURL = entry.id.url.deletingLastPathComponent().standardizedFileURL
                targetID = EntryID(url: parentURL)
            }
        } else {
            guard let rootEntry = entries.first else { return false }
            let rootURL = rootEntry.id.url.deletingLastPathComponent().standardizedFileURL
            targetID = EntryID(url: rootURL)
        }

        let isCopy = dragState?.isCopyMode ?? false
        if isCopy {
            onCopyEntries(sourceIDs, targetID)
        } else {
            onMoveEntries(sourceIDs, targetID)
        }
        return true
    }
}

// MARK: - FT-R9 悬停展开 + 面板边缘自动滚动

extension FileTreeTableView.Coordinator {

    /// 悬停 `delay` 秒后自动展开 `entryID` 对应目录。
    func scheduleHoverExpand(entryID: EntryID, after delay: TimeInterval) {
        guard let state = dragState else { return }
        state.cancelHoverExpand()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onExpandDirectory(entryID)
        }
        state.hoverExpandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 检查鼠标是否在面板边缘区域，若是则启动自动滚动；否则停止。
    func updateEdgeScroll(for location: NSPoint, in tableView: NSTableView) {
        guard let scrollView = tableView.enclosingScrollView else { return }
        let visibleHeight = scrollView.contentView.bounds.height
        guard visibleHeight > 0 else { return }

        let localPoint = tableView.convert(location, from: nil)
        let visibleRect = scrollView.contentView.documentVisibleRect
        let relativeY = (localPoint.y - visibleRect.minY) / visibleHeight

        let scrollDelta: CGFloat
        if relativeY <= 0.05 {
            scrollDelta = 8
        } else if relativeY <= 0.15 {
            scrollDelta = 5
        } else if relativeY >= 0.95 {
            scrollDelta = -8
        } else if relativeY >= 0.85 {
            scrollDelta = -5
        } else {
            dragState?.cancelEdgeScroll()
            return
        }

        if dragState?.edgeScrollWork != nil { return }
        startEdgeScroll(delta: scrollDelta, in: scrollView)
    }

    private func startEdgeScroll(delta: CGFloat, in scrollView: NSScrollView) {
        guard let state = dragState else { return }

        let work = DispatchWorkItem { [weak self, weak scrollView] in
            guard let self, let scrollView,
                  self.dragState?.edgeScrollWork != nil else { return }

            let current = scrollView.contentView.bounds.origin
            let maxY = scrollView.contentView.documentRect.height
                - scrollView.contentView.bounds.height
            let newY = max(0, min(current.y - delta, maxY))
            scrollView.contentView.scroll(to: NSPoint(x: current.x, y: newY))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            self.dragState?.edgeScrollWork = nil
            self.startEdgeScroll(delta: delta, in: scrollView)
        }
        state.edgeScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
    }
}

// MARK: - FT-R8 键盘感知 NSTableView 子类

/// NSTableView 子类，负责将 Cmd+N / Cmd+Shift+N / Return / Esc 键盘事件
/// 分发给 `FileTreeTableView` 的回调，而非走系统默认响应链。
///
/// 对标 VSCode `WorkbenchCompressibleAsyncDataTree` 中注册的 `KeyCode.Enter/Escape`
/// 键盘事件（由 `ExplorerView._onKeyDown` 处理）。
final class FileTreeKeyboardTableView: NSTableView {

    var onNewFile: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRenameSelected: (() -> Void)?
    var onCancelEdit: (() -> Void)?

    /// FT-R16: 右键菜单提供者：传入点击行索引，返回 NSMenu（nil = 不显示菜单）。
    /// 由 Coordinator 在 makeNSView 时设置。
    var contextMenuProvider: ((Int) -> NSMenu?)?

    /// 当前是否处于编辑态（由 Coordinator 在 updateNSView 时同步）。
    var isInlineEditing: Bool = false

    /// 确保 table view 能成为 first responder 以接收键盘事件。
    /// NSTableView 默认返回 true，但显式声明确保 focusRingType = .none 不影响行为。
    override var acceptsFirstResponder: Bool { true }

    /// FT-R16: 覆写 NSResponder.menu(for:)，将点击位置转换为行索引后委托给 provider。
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

    override func keyDown(with event: NSEvent) {
        let cmd   = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        switch (event.keyCode, cmd, shift, isInlineEditing) {
        case (45, true, false, false):  // Cmd+N — 新建文件
            onNewFile?()
        case (45, true, true,  false):  // Cmd+Shift+N — 新建文件夹
            onNewFolder?()
        case (36, false, false, false): // Return（非编辑态）— 重命名
            onRenameSelected?()
        case (53, _, _, true):          // Esc（编辑态）— 保险回退（优先由 TextField 拦截）
            onCancelEdit?()
        default:
            super.keyDown(with: event)
        }
    }
}
