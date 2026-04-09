import AppKit

/// AI Agent 变更条纹 Lane：在 gutter 绘制 3pt 宽的变更条纹，
/// 标记 Agent 修改的行（紫/青/粉，区别于 git diff 的绿/橙/红）。
///
/// VSCode 参考：`dirtydiffDecorator.ts`，git diff stripe 3px border-left。
/// Zed 参考：`element.rs` `paint_gutter_diff_hunks`，宽度约 0.275 × line_height。
/// agentGui：沿用 F13 GitDiffStripeLane 相同宽度（4pt），不同颜色集合。
@MainActor
final class AgentDiffStripeLane: CodeEditorGutterLane {

    let id = "agentDiffStripe"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        4   // 3pt 条纹 + 1pt 右侧留白（与 GitDiffStripeLane 相同宽度）
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return }

        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )
        let stripeWidth: CGFloat = 3
        let stripeX = laneRect.minX

        for (lineNumber, kind) in snapshot.agentChangeDiffByLine {
            guard let metric = lineMetricsByLine[lineNumber] else { continue }

            switch kind {
            case .added:
                // 紫色：区分 git added（绿色）
                let stripeRect = NSRect(
                    x: stripeX, y: metric.rect.minY,
                    width: stripeWidth, height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                NSColor.systemPurple.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .modified:
                // 青色：区分 git modified（橙色）
                let stripeRect = NSRect(
                    x: stripeX, y: metric.rect.minY,
                    width: stripeWidth, height: metric.rect.height
                )
                guard stripeRect.intersects(dirtyRect) else { continue }
                NSColor.systemCyan.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: stripeRect).fill()

            case .deleted:
                // 粉色三角：区分 git deleted（红色三角）
                let markerHeight: CGFloat = 6
                let markerWidth: CGFloat = 4
                let markerY = metric.rect.minY - markerHeight / 2
                let markerRect = NSRect(x: stripeX, y: markerY,
                                        width: markerWidth, height: markerHeight)
                guard markerRect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
                NSColor.systemPink.withAlphaComponent(0.90).setFill()
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
        nil     // 装饰性，不响应点击（Accept/Reject 由 ChangeReviewActionLane 处理）
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }

        let prev = previous.agentChangeDiffByLine
        let curr = current.agentChangeDiffByLine

        guard prev != curr else { return .none }

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
