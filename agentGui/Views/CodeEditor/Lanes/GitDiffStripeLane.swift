import AppKit

/// Git Diff Stripe Lane：在 gutter 左侧绘制 3pt 宽的颜色条纹，
/// 可视化当前文件相对 HEAD 的行级变更状态。
///
/// 视觉设计参考 VSCode `scm.diffDecorations`（宽 3 px border-left）
/// 和 Zed `paint_gutter_diff_hunks`（`gutter_strip_width = 0.275 * line_height`）。
@MainActor
final class GitDiffStripeLane: CodeEditorGutterLane {

    let id = "gitDiffStripe"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        4   // 3pt 条纹 + 1pt 右侧留白
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.gitDiffByLine.isEmpty else { return }

        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )
        let stripeWidth: CGFloat = 3
        let stripeX = laneRect.minX

        for (lineNumber, kind) in snapshot.gitDiffByLine {
            guard let metric = lineMetricsByLine[lineNumber] else { continue }

            switch kind {
            case .added, .modified:
                let color = kind == .added ? NSColor.systemGreen : NSColor.systemOrange
                let stripeRect = NSRect(
                    x: stripeX,
                    y: metric.rect.minY,
                    width: stripeWidth,
                    height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                color.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .deleted:
                // 删除标记：在行顶边界绘制小三角（高 6pt）
                // 参照 VSCode dirty-diff-deleted glyph 风格
                let markerHeight: CGFloat = 6
                let markerWidth: CGFloat = 4
                let markerY = metric.rect.minY - markerHeight / 2   // 居中于行边界
                let markerRect = NSRect(
                    x: stripeX,
                    y: markerY,
                    width: markerWidth,
                    height: markerHeight
                )
                guard markerRect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }

                NSColor.systemRed.withAlphaComponent(0.90).setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: markerRect.minX, y: markerRect.minY))
                path.line(to: NSPoint(x: markerRect.maxX, y: markerRect.minY))
                path.line(to: NSPoint(x: (markerRect.minX + markerRect.maxX) / 2,
                                      y: markerRect.maxY))
                path.close()
                path.fill()
            }
        }
    }

    // MARK: - Hit Test

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        nil     // Diff stripe 为装饰性，不响应点击
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }

        let prev = previous.gitDiffByLine
        let curr = current.gitDiffByLine

        guard prev != curr else { return .none }

        // 计算变更行集合（新增、删除、状态变化的行）
        var changedLines = Set<Int>()
        for (line, kind) in curr where prev[line] != kind {
            changedLines.insert(line)
        }
        for line in prev.keys where curr[line] == nil {
            changedLines.insert(line)
        }

        return .lines(changedLines)
    }
}
