import AppKit

/// Accept / Reject Action Lane：在有 Agent 变更的行绘制 ✓/✗ 小图标，
/// 点击左半区 = Accept（返回正行号），点击右半区 = Reject（返回负行号）。
///
/// 设计参考：
/// - VSCode DirtyDiffWidget：在 hover 弹出框内提供 Accept Hunk / Revert Hunk 按钮。
/// - Zed：在 gutter diff hunk header row 附近通过 HitboxId 区分 accept/reject 点击。
/// - F24 简化：直接在 gutter 绘制双图标，不需要 hover/popover。
///
/// Hit test 编码约定（F24 内部约定，FileEditorView 解码）：
/// - 返回正整数 → accept 点击，值为行号（1-based）
/// - 返回负整数 → reject 点击，值为 -lineNumber
/// - 返回 nil   → 未命中可点击区域
@MainActor
final class ChangeReviewActionLane: CodeEditorGutterLane {

    let id = "changeReviewAction"
    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Preferred Width

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        // 有 agent diff 时显示 ✓✗ 双图标区（30pt），无 diff 时折叠为 0
        snapshot.agentChangeDiffByLine.isEmpty ? 0 : 30
    }

    // MARK: - Draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return }

        // 找到每个 hunk 起始行（连续变更块的第一行）
        let hunkStartLines = detectHunkStartLines(from: snapshot.agentChangeDiffByLine)
        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )

        let iconSize: CGFloat = 11
        let midX = laneRect.midX

        for startLine in hunkStartLines {
            guard let metric = lineMetricsByLine[startLine] else { continue }
            let iconY = metric.rect.midY - iconSize / 2

            // ✓ 图标（左半）
            let acceptRect = NSRect(x: laneRect.minX + 2, y: iconY, width: iconSize, height: iconSize)
            if acceptRect.intersects(dirtyRect) {
                drawSymbol("checkmark.circle", in: acceptRect, color: .systemGreen, appearance: appearance)
            }

            // ✗ 图标（右半）
            let rejectRect = NSRect(x: midX + 2, y: iconY, width: iconSize, height: iconSize)
            if rejectRect.intersects(dirtyRect) {
                drawSymbol("xmark.circle", in: rejectRect, color: .systemRed, appearance: appearance)
            }
        }
    }

    // MARK: - Hit Test

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        guard !snapshot.agentChangeDiffByLine.isEmpty else { return nil }

        let hunkStartLines = detectHunkStartLines(from: snapshot.agentChangeDiffByLine)
        let lineMetricsByLine = Dictionary(
            uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) }
        )

        for startLine in hunkStartLines {
            guard let metric = lineMetricsByLine[startLine] else { continue }
            let iconY = metric.rect.midY - 6
            let hitRow = NSRect(x: laneRect.minX, y: iconY, width: laneRect.width, height: 12)
            guard hitRow.contains(point) else { continue }

            // 左半 → accept（正行号）；右半 → reject（负行号）
            if point.x < laneRect.midX {
                return startLine          // 正数 = accept
            } else {
                return -startLine         // 负数 = reject（FileEditorView 用 abs() 还原）
            }
        }
        return nil
    }

    // MARK: - Invalidation Plan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else { return .full }
        guard previous.agentChangeDiffByLine != current.agentChangeDiffByLine else { return .none }
        // hunk 有变化时全量重绘 action lane
        return .full
    }

    // MARK: - Hunk Detection

    /// 从行级 diff map 中找出每个连续变更块的起始行（hunk start lines）。
    /// 例如 [3:.added, 4:.added, 7:.modified] → [3, 7]
    private func detectHunkStartLines(
        from diffByLine: [Int: CodeEditorGitDiffKind]
    ) -> [Int] {
        guard !diffByLine.isEmpty else { return [] }
        let sortedLines = diffByLine.keys.sorted()
        var result: [Int] = []
        var prevLine: Int? = nil
        for line in sortedLines {
            if let prev = prevLine, line == prev + 1 {
                // 连续行，属于同一 hunk
            } else {
                result.append(line)
            }
            prevLine = line
        }
        return result
    }

    // MARK: - Icon Drawing

    private func drawSymbol(
        _ name: String,
        in rect: NSRect,
        color: NSColor,
        appearance: NSAppearance?
    ) {
        // 使用 SF Symbols 渲染小图标
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }

        let tinted: NSImage
        if let tintedImage = image.copy() as? NSImage {
            tintedImage.isTemplate = false
            tintedImage.lockFocus()
            color.withAlphaComponent(0.80).set()
            NSRect(origin: .zero, size: tintedImage.size).fill(using: .sourceAtop)
            tintedImage.unlockFocus()
            tinted = tintedImage
        } else {
            tinted = image
        }
        tinted.draw(in: rect)
    }
}
