// agentGui/Views/CodeEditor/CodeEditorCompletionPanel.swift
import AppKit

// MARK: - Item Row View

/// 单条补全项的行视图（kind icon + label + detail）。
private final class CompletionItemRowView: NSTableCellView {
    let kindLabel = NSTextField(labelWithString: "")
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        kindLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [kindLabel, nameLabel, detailLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: CodeEditorCompletionItem, isSelected: Bool) {
        kindLabel.stringValue = item.kind.map { kindString($0) } ?? " "
        nameLabel.stringValue = item.label
        detailLabel.stringValue = item.detail ?? ""
        nameLabel.textColor = isSelected ? .selectedControlTextColor : .labelColor
        detailLabel.textColor = isSelected
            ? .selectedControlTextColor.withAlphaComponent(0.6)
            : .secondaryLabelColor
    }

    private func kindString(_ kind: LSPCompletionItemKind) -> String {
        switch kind {
        case .function, .method: return "ƒ"
        case .class, .struct: return "C"
        case .variable, .field: return "v"
        case .keyword: return "K"
        case .snippet: return "⎇"
        case .module: return "M"
        case .property: return "p"
        case .enumMember, .enum: return "E"
        case .interface: return "I"
        case .typeParameter: return "T"
        default: return "·"
        }
    }
}

// MARK: - Panel

/// 浮动补全面板（NSPanel + NSTableView）。
/// 持有者（CodeEditorTextView.Coordinator）负责定位和更新。
/// 对应 VSCode SuggestWidget 的展示职责。
final class CodeEditorCompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let itemHeight: CGFloat = 28
    static let maxVisibleItems = 10
    static let panelWidth: CGFloat = 380
    private static let chromePadding: CGFloat = 8
    private static let cornerRadius: CGFloat = 14

    // MARK: Windowing
    private(set) var panel: NSPanel
    private let containerView: NSVisualEffectView
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // MARK: State
    private var items: [CodeEditorCompletionItem] = []
    private var selectedIndex: Int = 0
    private var isApplyingProgrammaticSelection = false
    var onAccept: ((CodeEditorCompletionItem) -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0)
        let container = NSVisualEffectView(frame: contentRect)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        self.containerView = container
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.alphaValue = 0

        super.init()

        // Container view with visual effect
        panel.contentView = container

        // Table setup
        tableView.headerView = nil
        tableView.rowHeight = Self.itemHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(acceptSelected)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.chromePadding),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.chromePadding),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromePadding),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.chromePadding)
        ])
    }

    // MARK: - Public API

    func update(session: CodeEditorCompletionSession) {
        guard !session.isLoading else { return }
        items = session.items
        selectedIndex = session.selectedIndex
        reloadAndResize()
        applySelectionIfNeeded()
        scrollToSelected()
    }

    func show(anchoredBelow cursorRect: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { return }
        positionPanel(below: cursorRect, in: window)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            panel.animator().alphaValue = 1
        } else {
            animateChromeRefresh()
        }
    }

    func hide() {
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [panel] in
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        items = []
    }

    func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        tableView.reloadData()
        applySelectionIfNeeded()
        scrollToSelected()
    }

    func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        tableView.reloadData()
        applySelectionIfNeeded()
        scrollToSelected()
    }

    func acceptSelectedItem() -> CodeEditorCompletionItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.backgroundColor = .clear
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompletionItemRowView
            ?? CompletionItemRowView(frame: .zero)
        cell.identifier = id
        let isSelected = row == selectedIndex
        cell.configure(item: items[row], isSelected: isSelected)
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 8
        cell.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard isApplyingProgrammaticSelection == false else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        guard row != selectedIndex else { return }

        let previousIndex = selectedIndex
        selectedIndex = row

        if items.indices.contains(previousIndex) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: previousIndex), columnIndexes: IndexSet(integer: 0))
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedIndex), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Private

    @objc private func acceptSelected() {
        guard let item = acceptSelectedItem() else { return }
        onAccept?(item)
    }

    private func reloadAndResize() {
        tableView.reloadData()
        let visibleCount = min(items.count, Self.maxVisibleItems)
        let panelHeight = CGFloat(visibleCount) * Self.itemHeight + (Self.chromePadding * 2)
        var frame = panel.frame
        frame.size = CGSize(width: Self.panelWidth, height: panelHeight)
        panel.setFrame(frame, display: true)
        containerView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func positionPanel(below cursorRect: NSRect, in window: NSWindow) {
        let screenCursorRect = window.convertToScreen(cursorRect)
        let visibleCount = min(max(items.count, 1), Self.maxVisibleItems)
        let panelHeight = CGFloat(visibleCount) * Self.itemHeight + (Self.chromePadding * 2)
        var origin = NSPoint(
            x: screenCursorRect.minX,
            y: screenCursorRect.minY - panelHeight - 4
        )
        // 检查下方空间是否足够，否则显示在光标上方
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.y < screenFrame.minY {
                origin.y = screenCursorRect.maxY + 4
            }
            if origin.x + Self.panelWidth > screenFrame.maxX {
                origin.x = screenFrame.maxX - Self.panelWidth - 8
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func scrollToSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func applySelectionIfNeeded() {
        guard items.indices.contains(selectedIndex) else { return }
        guard tableView.selectedRow != selectedIndex else { return }

        isApplyingProgrammaticSelection = true
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
    }

    private func animateChromeRefresh() {
        guard panel.isVisible else { return }

        let previousTransform = containerView.layer?.transform
        containerView.layer?.transform = CATransform3DMakeScale(0.985, 0.985, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            containerView.animator().alphaValue = 1
        } completionHandler: { [weak containerView] in
            containerView?.layer?.transform = previousTransform ?? CATransform3DIdentity
        }
    }
}
