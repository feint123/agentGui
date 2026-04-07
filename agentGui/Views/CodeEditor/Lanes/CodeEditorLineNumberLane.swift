import AppKit

/// 行号 Gutter Lane
/// 从 CodeEditorGutterRenderer 迁移行号绘制逻辑
@MainActor
final class CodeEditorLineNumberLane: CodeEditorGutterLane {

    let id = "lineNumber"

    var onPreferredWidthChange: (() -> Void)?

    // MARK: - Internal Caches

    private struct WidthCacheKey: Equatable {
        let digits: Int
        let appearanceName: String?
    }

    private struct AttributeCacheKey: Hashable {
        let isCurrentLine: Bool
    }

    private var cachedWidthKey: WidthCacheKey?
    private var cachedWidth: CGFloat?
    private var cachedParagraphStyle: NSParagraphStyle?
    private var cachedAttributes: [AttributeCacheKey: [NSAttributedString.Key: Any]] = [:]

    // MARK: - preferredWidth

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        let digits = max(2, String(max(snapshot.lineCount, 1)).count)
        let key = WidthCacheKey(digits: digits, appearanceName: appearance?.name.rawValue)
        if key == cachedWidthKey, let cachedWidth {
            return cachedWidth
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let sample = String(repeating: "9", count: digits)
        let measuredWidth = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
        let width = measuredWidth + 20
        cachedWidthKey = key
        cachedWidth = width
        return width
    }

    // MARK: - draw

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        let width = preferredWidth(for: snapshot, appearance: appearance)
        let lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })

        for line in snapshot.visibleLineRange {
            guard let metric = lineMetricsByLine[line] else {
                continue
            }

            let lineRect = NSRect(
                x: laneRect.origin.x,
                y: metric.rect.minY,
                width: width,
                height: metric.rect.height
            ).integral
            guard lineRect.intersects(dirtyRect) else {
                continue
            }

            let isCurrentLine = snapshot.cursorLineNumbers.contains(line)
            if isCurrentLine {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.08).setFill()
                lineRect.fill()
            }

            let labelRect = NSRect(
                x: laneRect.origin.x,
                y: lineRect.minY,
                width: width - 10,
                height: lineRect.height
            )
            NSString(string: "\(line)").draw(in: labelRect, withAttributes: attributes(isCurrentLine: isCurrentLine))
        }
    }

    // MARK: - hitTest

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        for metric in snapshot.lineMetrics {
            if point.y >= metric.rect.minY && point.y < metric.rect.maxY {
                return metric.line
            }
        }
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

        let changedLines = changedCurrentLines(from: previous, to: current)
            .union(changedMetricLines(from: previous, to: current))

        if current.lineCount != previous.lineCount {
            return .full
        }

        if changedLines.isEmpty {
            return .none
        }

        return .lines(changedLines)
    }

    // MARK: - Private Helpers

    private func attributes(isCurrentLine: Bool) -> [NSAttributedString.Key: Any] {
        let key = AttributeCacheKey(isCurrentLine: isCurrentLine)
        if let cached = cachedAttributes[key] {
            return cached
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let color: NSColor = isCurrentLine ? .labelColor : .secondaryLabelColor
        let style = paragraphStyle()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        cachedAttributes[key] = attrs
        return attrs
    }

    private func paragraphStyle() -> NSParagraphStyle {
        if let cached = cachedParagraphStyle {
            return cached
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        cachedParagraphStyle = style
        return style
    }

    private func changedCurrentLines(
        from previous: CodeEditorGutterViewportSnapshot,
        to current: CodeEditorGutterViewportSnapshot
    ) -> Set<Int> {
        if previous.cursorLineNumbers == current.cursorLineNumbers {
            return []
        }
        return previous.cursorLineNumbers.union(current.cursorLineNumbers)
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
