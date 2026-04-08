// agentGui/Views/FileTree/FileTreeTableRowView.swift
import AppKit

/// 自定义行背景视图。
///
/// 对标 Zed render_entry() 中 `.bg(bg_color).hover(|s| s.bg(bg_hover_color))` 逻辑。
/// VSCode 通过 CSS 实现相同效果：`list-item-background-active`。
final class FileTreeTableRowView: NSTableRowView {

    // MARK: - 颜色常量

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
