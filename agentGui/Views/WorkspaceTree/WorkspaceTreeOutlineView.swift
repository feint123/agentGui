import AppKit
import SwiftUI

struct WorkspaceTreeOutlineView: NSViewRepresentable {
    struct ActionHandlers {
        let previewDiff: (GitFileChange, Bool) -> Void
        let revealInFinder: (FileNode) -> Void
        let copyRelativePath: (FileNode) -> Void
        let newFile: (FileNode) -> Void
        let newFolder: (FileNode) -> Void
        let rename: (FileNode) -> Void
        let delete: (FileNode) -> Void
        let canMoveSelection: (FileNode?) -> Bool
        let moveSelection: (FileNode?) -> Bool
        let newFileFromSelection: () -> Void
        let newFolderFromSelection: () -> Void
        let renameSelection: () -> Void
        let deleteSelection: () -> Void
        let copySelectionRelativePaths: () -> Void
        let revealSelectionInFinder: () -> Void
        let inlineEditChange: (String) -> Void
        let inlineEditCommit: () -> Void
        let inlineEditCancel: () -> Void
    }

    let nodes: [FileNode]
    let selectionIDs: Set<URL>
    let primarySelectionID: URL?
    let inlineEdit: WorkspaceTreeInlineEdit?
    let expandsMatchingBranches: Bool
    let gitChangeProvider: (FileNode) -> GitFileChange?
    let onSelectionChange: (Set<URL>, URL?) -> Void
    let actions: ActionHandlers
    let onDemandLoadDirectory: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let outlineView = WorkspaceNativeOutlineView()
        outlineView.headerView = nil
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 26
        outlineView.rowSizeStyle = .small
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.selectionHighlightStyle = .none
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnSelection = false
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([WorkspaceNativeOutlineView.dragType])
        outlineView.setAccessibilityIdentifier("workspace.fileTree.outline")

        let column = NSTableColumn(identifier: .workspaceTreeColumn)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.menuProvider = { [weak coordinator = context.coordinator, weak outlineView] row in
            guard let coordinator, let outlineView else { return nil }
            return coordinator.menu(forRow: row, in: outlineView)
        }
        outlineView.keyboardActionHandler = { [weak coordinator = context.coordinator] action in
            coordinator?.handleKeyboardAction(action) ?? false
        }

        scrollView.documentView = outlineView
        context.coordinator.refresh(outlineView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? WorkspaceNativeOutlineView else { return }
        context.coordinator.parent = self
        context.coordinator.refresh(outlineView)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: WorkspaceTreeOutlineView

        private var expandedIDs: Set<URL> = []
        private var isApplyingProgrammaticSelection = false
        private var contextMenuNode: FileNode?
        private var contextMenuGitChange: GitFileChange?
        private var cachedNodesFingerprint: Int = 0
        private var cachedInlineEditNodeID: URL?

        init(parent: WorkspaceTreeOutlineView) {
            self.parent = parent
        }

        fileprivate func refresh(_ outlineView: WorkspaceNativeOutlineView) {
            let newFingerprint = Self.nodesFingerprint(parent.nodes)
            let newInlineEditID = parent.inlineEdit?.editingNodeID
            let dataChanged = newFingerprint != cachedNodesFingerprint
            let inlineEditChanged = newInlineEditID != cachedInlineEditNodeID

            if dataChanged || inlineEditChanged {
                cachedNodesFingerprint = newFingerprint
                cachedInlineEditNodeID = newInlineEditID
                outlineView.reloadData()
                restoreExpansion(on: outlineView)
            }

            synchronizeSelection(on: outlineView)
            refreshVisibleCellAppearance(on: outlineView)
        }

        /// Lightweight recursive fingerprint over the tree structure (URLs + load state + child count).
        /// Hash collisions are negligible; worst case is a missed one-frame update.
        private static func nodesFingerprint(_ nodes: [FileNode]) -> Int {
            var hasher = Hasher()
            fingerprintHelper(nodes, &hasher)
            return hasher.finalize()
        }

        private static func fingerprintHelper(_ nodes: [FileNode], _ hasher: inout Hasher) {
            hasher.combine(nodes.count)
            for node in nodes {
                hasher.combine(node.id)
                hasher.combine(node.childrenLoadState)
                if let children = node.children {
                    fingerprintHelper(children, &hasher)
                }
            }
        }

        /// Reconfigure only the cells visible on screen (selection highlight, git badge, etc.)
        /// without full reloadData. This is the fast path for selection-only changes.
        private func refreshVisibleCellAppearance(on outlineView: NSOutlineView) {
            let visibleRange = outlineView.rows(in: outlineView.visibleRect)
            guard visibleRange.length > 0 else { return }
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                guard let node = fileNode(from: outlineView.item(atRow: row)),
                      let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? WorkspaceTreeNativeCellView else {
                    continue
                }
                let isSelected = parent.selectionIDs.contains(node.id.standardizedFileURL)
                let gitChange = parent.gitChangeProvider(node)
                let isInlineEditing = parent.inlineEdit?.editingNodeID == node.id
                cellView.configure(
                    node: node,
                    isSelected: isSelected,
                    gitChange: gitChange,
                    isInlineEditing: isInlineEditing,
                    draftName: parent.inlineEdit?.draftName,
                    onInlineEditChange: parent.actions.inlineEditChange,
                    onInlineEditCommit: parent.actions.inlineEditCommit,
                    onInlineEditCancel: parent.actions.inlineEditCancel
                )
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(for: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(for: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            guard node.isDirectory else { return false }
            // .notLoaded 目录：内容未知，显示展开三角（与 VSCode ExplorerItem.hasChildren() 一致）
            if node.childrenLoadState == .notLoaded { return true }
            return !(node.children ?? []).isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = fileNode(from: item) else { return false }
            guard node.isDirectory else { return false }
            if node.childrenLoadState == .notLoaded { return true }
            return !(node.children ?? []).isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = fileNode(from: item) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("WorkspaceTreeCell")
            let cellView: WorkspaceTreeNativeCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? WorkspaceTreeNativeCellView {
                cellView = reused
            } else {
                cellView = WorkspaceTreeNativeCellView()
                cellView.identifier = identifier
            }

            let isSelected = parent.selectionIDs.contains(node.id.standardizedFileURL)
            let gitChange = parent.gitChangeProvider(node)
            let isInlineEditing = parent.inlineEdit?.editingNodeID == node.id
            cellView.configure(
                node: node,
                isSelected: isSelected,
                gitChange: gitChange,
                isInlineEditing: isInlineEditing,
                draftName: parent.inlineEdit?.draftName,
                onInlineEditChange: parent.actions.inlineEditChange,
                onInlineEditCommit: parent.actions.inlineEditCommit,
                onInlineEditCancel: parent.actions.inlineEditCancel
            )

            return cellView
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            WorkspaceTreeTableRowView()
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? WorkspaceNativeOutlineView,
                  !isApplyingProgrammaticSelection else {
                return
            }

            let selectedIDs = selectedNodeIDs(in: outlineView)
            let primaryID = resolvedPrimaryID(in: outlineView, selectedIDs: selectedIDs)
            parent.onSelectionChange(selectedIDs, primaryID)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            expandedIDs.insert(node.id.standardizedFileURL)
            // 若该目录尚未加载，触发按需扫描
            if node.childrenLoadState == .notLoaded {
                parent.onDemandLoadDirectory?(node.id.standardizedFileURL)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            expandedIDs.remove(node.id.standardizedFileURL)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = fileNode(from: item) else { return nil }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(node.id.standardizedFileURL.path, forType: WorkspaceNativeOutlineView.dragType)
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex childIndex: Int) -> NSDragOperation {
            let destination = fileNode(from: item)
            guard parent.actions.canMoveSelection(destination) else {
                return []
            }

            if destination == nil {
                let targetIndex = childIndex == NSOutlineViewDropOnItemIndex
                    ? outlineView.numberOfChildren(ofItem: nil)
                    : max(childIndex, 0)
                outlineView.setDropItem(nil, dropChildIndex: targetIndex)
            } else {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
            let destination = fileNode(from: item)
            return parent.actions.moveSelection(destination)
        }

        func menu(forRow row: Int, in outlineView: NSOutlineView) -> NSMenu? {
            guard row >= 0,
                  let node = fileNode(from: outlineView.item(atRow: row)) else {
                return nil
            }

            contextMenuNode = node
            contextMenuGitChange = parent.gitChangeProvider(node)
            return WorkspaceTreeContextMenuFactory.makeMenu(
                gitChange: contextMenuGitChange,
                target: self,
                action: #selector(handleContextMenuAction(_:))
            )
        }

        @objc
        private func handleContextMenuAction(_ sender: NSMenuItem) {
            guard let node = contextMenuNode,
                  let rawValue = sender.representedObject as? String,
                  let action = WorkspaceTreeContextMenuAction(rawValue: rawValue) else {
                return
            }

            switch action {
            case .previewDiff:
                guard let contextMenuGitChange else { return }
                parent.actions.previewDiff(contextMenuGitChange, contextMenuGitChange.section == .staged)
            case .revealInFinder:
                parent.actions.revealInFinder(node)
            case .copyRelativePath:
                parent.actions.copyRelativePath(node)
            case .newFile:
                parent.actions.newFile(node)
            case .newFolder:
                parent.actions.newFolder(node)
            case .rename:
                parent.actions.rename(node)
            case .delete:
                parent.actions.delete(node)
            }
        }

        fileprivate func handleKeyboardAction(_ action: WorkspaceTreeKeyboardShortcut) -> Bool {
            switch action {
            case .newFile:
                parent.actions.newFileFromSelection()
            case .newFolder:
                parent.actions.newFolderFromSelection()
            case .rename:
                parent.actions.renameSelection()
            case .delete:
                parent.actions.deleteSelection()
            case .copyRelativePath:
                parent.actions.copySelectionRelativePaths()
            case .revealInFinder:
                parent.actions.revealSelectionInFinder()
            }

            return true
        }

        private func children(for item: Any?) -> [FileNode] {
            if let node = fileNode(from: item) {
                return node.children ?? []
            }
            return parent.nodes
        }

        private func fileNode(from item: Any?) -> FileNode? {
            item as? FileNode
        }

        private func selectedNodeIDs(in outlineView: NSOutlineView) -> Set<URL> {
            var selectedIDs: Set<URL> = []
            for row in outlineView.selectedRowIndexes {
                guard let node = fileNode(from: outlineView.item(atRow: row)) else { continue }
                selectedIDs.insert(node.id.standardizedFileURL)
            }
            return selectedIDs
        }

        private func resolvedPrimaryID(in outlineView: WorkspaceNativeOutlineView, selectedIDs: Set<URL>) -> URL? {
            if let pendingRow = outlineView.takePendingPrimaryRow(),
               pendingRow >= 0,
               let node = fileNode(from: outlineView.item(atRow: pendingRow)),
               selectedIDs.contains(node.id.standardizedFileURL) {
                return node.id.standardizedFileURL
            }

            guard let lastRow = outlineView.selectedRowIndexes.last,
                  let node = fileNode(from: outlineView.item(atRow: lastRow)) else {
                return nil
            }
            return node.id.standardizedFileURL
        }

        private func restoreExpansion(on outlineView: NSOutlineView) {
            if parent.expandsMatchingBranches {
                expandAllDirectories(in: parent.nodes, on: outlineView)
                return
            }

            for expandedID in expandedIDs {
                expandPath(to: expandedID, includeTarget: true, on: outlineView)
            }

            for selectedID in parent.selectionIDs {
                expandPath(to: selectedID, includeTarget: false, on: outlineView)
            }

            if let editingNodeID = parent.inlineEdit?.editingNodeID {
                expandPath(to: editingNodeID, includeTarget: false, on: outlineView)
            }
        }

        private func expandAllDirectories(in nodes: [FileNode], on outlineView: NSOutlineView) {
            for node in nodes where node.isDirectory {
                outlineView.expandItem(node)
                expandAllDirectories(in: node.children ?? [], on: outlineView)
            }
        }

        private func expandPath(to targetID: URL, includeTarget: Bool, on outlineView: NSOutlineView) {
            guard let path = path(to: targetID.standardizedFileURL, in: parent.nodes) else { return }

            let nodesToExpand = includeTarget ? path : Array(path.dropLast())
            for node in nodesToExpand where node.isDirectory {
                outlineView.expandItem(node)
            }
        }

        private func path(to targetID: URL, in nodes: [FileNode]) -> [FileNode]? {
            for node in nodes {
                if node.id.standardizedFileURL == targetID {
                    return [node]
                }

                if let childPath = path(to: targetID, in: node.children ?? []) {
                    return [node] + childPath
                }
            }
            return nil
        }

        private func synchronizeSelection(on outlineView: WorkspaceNativeOutlineView) {
            var targetRows = IndexSet()
            for row in 0..<outlineView.numberOfRows {
                guard let node = fileNode(from: outlineView.item(atRow: row)) else { continue }
                if parent.selectionIDs.contains(node.id.standardizedFileURL) {
                    targetRows.insert(row)
                }
            }

            guard outlineView.selectedRowIndexes != targetRows else { return }

            isApplyingProgrammaticSelection = true
            outlineView.selectRowIndexes(targetRows, byExtendingSelection: false)

            if let primarySelectionID = parent.primarySelectionID,
               let row = row(for: primarySelectionID, in: outlineView) {
                outlineView.pendingPrimaryRow = row
                outlineView.scrollRowToVisible(row)
            }
            isApplyingProgrammaticSelection = false
        }

        private func row(for targetID: URL, in outlineView: NSOutlineView) -> Int? {
            for row in 0..<outlineView.numberOfRows {
                guard let node = fileNode(from: outlineView.item(atRow: row)) else { continue }
                if node.id.standardizedFileURL == targetID.standardizedFileURL {
                    return row
                }
            }
            return nil
        }
    }
}

private final class WorkspaceNativeOutlineView: NSOutlineView {
    static let dragType = NSPasteboard.PasteboardType("com.feint.agentgui.workspace-tree")

    static let workspaceTreeColumn = NSUserInterfaceItemIdentifier("WorkspaceTreeColumn")

    var pendingPrimaryRow: Int?
    var menuProvider: ((Int) -> NSMenu?)?
    var keyboardActionHandler: ((WorkspaceTreeKeyboardShortcut) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        pendingPrimaryRow = row >= 0 ? row : nil

        // Detect if click lands on the disclosure triangle so we can avoid double-toggling
        let clickedDisclosure: Bool = {
            guard row >= 0 else { return false }
            let disclosureFrame = frameOfOutlineCell(atRow: row)
            return !disclosureFrame.isEmpty && disclosureFrame.contains(point)
        }()

        super.mouseDown(with: event)

        // After selection: if the row is a directory, toggle expand/collapse
        // (matches VS Code / Zed: plain single-click anywhere on the folder row toggles)
        // Skip if: modifier keys held (multi-select), disclosure triangle clicked (already toggled by super),
        // or not a single click.
        guard row >= 0,
              event.clickCount == 1,
              !clickedDisclosure,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              let node = item(atRow: row) as? FileNode,
              node.isDirectory else {
            return
        }

        if isItemExpanded(node) {
            animator().collapseItem(node)
        } else {
            animator().expandItem(node)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)

        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        pendingPrimaryRow = row >= 0 ? row : nil
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        if let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ), keyboardActionHandler?(action) == true {
            return
        }

        super.keyDown(with: event)
    }

    func takePendingPrimaryRow() -> Int? {
        defer { pendingPrimaryRow = nil }
        return pendingPrimaryRow
    }
}

private final class WorkspaceTreeTableRowView: NSTableRowView {
    override var isOpaque: Bool {
        false
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

private extension NSUserInterfaceItemIdentifier {
    static let workspaceTreeColumn = NSUserInterfaceItemIdentifier("WorkspaceTreeColumn")
}