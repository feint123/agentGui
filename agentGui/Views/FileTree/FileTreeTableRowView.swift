// agentGui/Views/FileTree/FileTreeTableRowView.swift
import AppKit

/// 自定义行背景视图。
///
/// 悬停状态由 `FileTreeHoverController`（表级 mouseMoved 追踪）统一管理，
/// 不使用 per-row NSTrackingArea——避免 NSTableView 行复用/滚动导致多行同时 hover 的问题。
///
/// 对标：
/// - Zed render_entry() 中 `.bg(bg_color).hover(|s| s.bg(bg_hover_color))`，
///   Zed 在 `on_mouse_move` 事件中计算当前 hover 行，而非每行注册 event handler。
/// - VSCode 的 CSS `:hover` 由浏览器引擎统一管理，不存在 per-row tracking 问题。
final class FileTreeTableRowView: NSTableRowView {

    // MARK: - 颜色常量

    /// 选中行：accent / 0.14
    private static let selectedColor = NSColor.controlAccentColor.withAlphaComponent(0.14)

    /// 悬停行：label / 0.07
    private static let hoverColor = NSColor.labelColor.withAlphaComponent(0.07)

    // MARK: - 状态

    /// 由 `FileTreeHoverController` 在 `mouseMoved` 中设置，非 per-row tracking。
    var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
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

    /// FT-R9: 自定义拖放高亮（替代 NSTableView 默认蓝色环）。
    /// 使用 accent 半透明填充 + 顶部 2pt accent 线，与 Zed `drop_target_background` 相似。
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        bounds.fill()
        // 顶部 2pt accent 强调线
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }

    // 禁用系统默认的选中绘制，由 drawBackground 托管
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

// MARK: - 表级悬停控制器

/// 在 NSTableView 层面通过 `mouseMoved` 追踪鼠标位置，计算当前 hover 行。
///
/// 与 per-row NSTrackingArea 方案对比：
/// - per-row 方案：行被 NSTableView 复用时 trackingArea.rect 仍是旧坐标，
///   滚动后多行可能同时处于 isHovered = true 状态。
/// - 本方案：只在 NSTableView 上注册一个 NSTrackingArea（mouseEnteredAndExited + mouseMoved），
///   在 `mouseMoved` 中用 `tableView.row(at:)` 精确计算当前行，确保始终只有一行 hover。
///
/// 对标 Zed `UniformList::on_mouse_move` 中 `hovered_entry = cx.mouse_position()...` 的设计。
final class FileTreeHoverController: NSResponder {
    private weak var tableView: NSTableView?
    private var trackingArea: NSTrackingArea?
    private var hoveredRow: Int = -1

    func install(on tableView: NSTableView) {
        self.tableView = tableView
        if let existing = trackingArea {
            tableView.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,   // 自动同步 visibleRect，无需手动 updateTrackingAreas
            ],
            owner: self,
            userInfo: nil
        )
        tableView.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    private func updateHover(with event: NSEvent) {
        guard let tableView else { return }
        let locationInTable = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: locationInTable)

        guard row != hoveredRow else { return }

        // 清除旧 hover
        if hoveredRow >= 0, hoveredRow < tableView.numberOfRows,
           let oldRow = tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? FileTreeTableRowView {
            oldRow.isHovered = false
        }

        hoveredRow = row

        // 设置新 hover
        if row >= 0, row < tableView.numberOfRows,
           let newRow = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileTreeTableRowView {
            newRow.isHovered = true
        }
    }

    func clearHover() {
        guard let tableView else { return }
        if hoveredRow >= 0, hoveredRow < tableView.numberOfRows,
           let oldRow = tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) as? FileTreeTableRowView {
            oldRow.isHovered = false
        }
        hoveredRow = -1
    }
}
