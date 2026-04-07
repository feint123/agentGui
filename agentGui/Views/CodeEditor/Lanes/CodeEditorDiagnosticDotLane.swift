import AppKit

/// 诊断圆点 Gutter Lane
/// 从 CodeEditorGutterRenderer 迁移诊断圆点绘制逻辑
@MainActor
final class CodeEditorDiagnosticDotLane: CodeEditorGutterLane {

    let id = "diagnosticDot"

    var onPreferredWidthChange: (() -> Void)?

    /// 固定列宽（F14 阶段可进一步动态化）
    private let fixedWidth: CGFloat = 16

    // MARK: - preferredWidth

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        fixedWidth
    }

    // MARK: - draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        let lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })

        for (line, summary) in snapshot.diagnosticsByLine {
            guard let metric = lineMetricsByLine[line] else {
                continue
            }

            let lineRect = NSRect(
                x: laneRect.origin.x,
                y: metric.rect.minY,
                width: laneRect.width,
                height: metric.rect.height
            ).integral
            guard lineRect.intersects(dirtyRect) else {
                continue
            }

            let dotSize: CGFloat = 5
            let markerRect = NSRect(
                x: laneRect.origin.x + (laneRect.width - dotSize) / 2,
                y: lineRect.midY - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            let path = NSBezierPath(ovalIn: markerRect)
            color(for: summary.highestSeverity).setFill()
            path.fill()
        }
    }

    // MARK: - hitTest

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        // 诊断圆点通常不需要命中测试；返回 nil
        return nil
    }

    // MARK: - invalidationPlan

    func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterLaneInvalidationPlan {
        guard let previous else {
            return .full
        }

        let changedLines = changedDiagnosticLines(from: previous, to: current)
            .union(changedMetricLines(from: previous, to: current))

        if changedLines.isEmpty {
            return .none
        }

        return .lines(changedLines)
    }

    // MARK: - Private Helpers

    private func color(for severity: LSPDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .information:
            return .systemBlue
        case .hint:
            return .secondaryLabelColor
        }
    }

    private func changedDiagnosticLines(
        from previous: CodeEditorGutterViewportSnapshot,
        to current: CodeEditorGutterViewportSnapshot
    ) -> Set<Int> {
        let previousLines = Set(previous.diagnosticsByLine.keys)
        let currentLines = Set(current.diagnosticsByLine.keys)
        let membershipChanges = previousLines.symmetricDifference(currentLines)
        let valueChanges = previous.diagnosticsByLine.compactMap { line, summary in
            current.diagnosticsByLine[line] == summary ? nil : line
        }
        return membershipChanges.union(valueChanges)
    }

    private func changedMetricLines(
        from previous: CodeEditorGutterViewportSnapshot,
        to current: CodeEditorGutterViewportSnapshot
    ) -> Set<Int> {
        let previousMetricsByLine = Dictionary(uniqueKeysWithValues: previous.lineMetrics.map { ($0.line, $0) })
        let currentMetricsByLine = Dictionary(uniqueKeysWithValues: current.lineMetrics.map { ($0.line, $0) })
        let membershipChanges = Set(previousMetricsByLine.keys).symmetricDifference(Set(currentMetricsByLine.keys))
        let valueChanges = previousMetricsByLine.compactMap { line, metric in
            currentMetricsByLine[line] == metric ? nil : line
        }
        return membershipChanges.union(valueChanges)
    }
}
