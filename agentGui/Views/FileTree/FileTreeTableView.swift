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

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, selection: selection, onSelect: onSelect,
                    onToggleExpand: onToggleExpand, onDoubleClick: onDoubleClick,
                    onUnfoldSegment: onUnfoldSegment)
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
        coordinator.onUnfoldSegment = onUnfoldSegment

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
        weak var tableView: NSTableView?

        /// 防止 tableViewSelectionDidChange 循环触发
        private var isSyncingSelection = false

        init(entries: [VisibleEntry], selection: FileTreeSelection,
             onSelect: @escaping (EntryID, SelectionModifier) -> Void,
             onToggleExpand: @escaping (EntryID) -> Void,
             onDoubleClick: @escaping (EntryID) -> Void,
             onUnfoldSegment: ((EntryID) -> Void)? = nil) {
            self.entries = entries
            self.selection = selection
            self.onSelect = onSelect
            self.onToggleExpand = onToggleExpand
            self.onDoubleClick = onDoubleClick
            self.onUnfoldSegment = onUnfoldSegment
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
                onToggle: { [weak self] id in self?.onToggleExpand(id) },
                onUnfoldSegment: { [weak self] id in self?.onUnfoldSegment?(id) }
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
