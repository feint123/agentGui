import AppKit

/// Drawing logic for the line-number gutter (legacy).
/// As of F11, drawing is handled by `CodeEditorLineNumberLane` and `CodeEditorDiagnosticDotLane`.
/// This struct is retained for host-level scroll-plan detection in `CodeEditorGutterView`.
@available(*, deprecated, message: "Use CodeEditorLineNumberLane and CodeEditorDiagnosticDotLane instead.")
struct CodeEditorGutterRenderer {
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

    mutating func requiredWidth(for snapshot: CodeEditorGutterViewportSnapshot, appearance: NSAppearance?) -> CGFloat {
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

    mutating func invalidationPlan(
        from previous: CodeEditorGutterViewportSnapshot?,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterInvalidationPlan {
        guard let previous else {
            return .full
        }

        if let scrollPlan = scrollPlan(from: previous, to: current) {
            return scrollPlan
        }

        let changedLines = changedCurrentLines(from: previous, to: current)
            .union(changedMetricLines(from: previous, to: current))
            .union(changedDiagnosticLines(from: previous, to: current))

        return .redraw(lines: changedLines, redrawSeparator: false)
    }

    mutating func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        in dirtyRect: NSRect,
        bounds: NSRect,
        appearance: NSAppearance?
    ) {
        let width = requiredWidth(for: snapshot, appearance: appearance)
        let lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })

        for line in snapshot.visibleLineRange {
            guard let metric = lineMetricsByLine[line] else {
                continue
            }

            let lineRect = NSRect(x: 0, y: metric.rect.minY, width: width, height: metric.rect.height).integral
            guard lineRect.intersects(dirtyRect) else {
                continue
            }

            let isCurrentLine = snapshot.currentLine == line
            if isCurrentLine {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.08).setFill()
                lineRect.fill()
            }

            let labelRect = NSRect(x: 0, y: lineRect.minY, width: width - 10, height: lineRect.height)
            NSString(string: "\(line)").draw(in: labelRect, withAttributes: attributes(isCurrentLine: isCurrentLine))

            if let summary = snapshot.diagnosticsByLine[line] {
                let markerRect = NSRect(x: width - 8, y: lineRect.midY - 2.5, width: 5, height: 5)
                let path = NSBezierPath(ovalIn: markerRect)
                color(for: summary.highestSeverity).setFill()
                path.fill()
            }
        }
    }

    private func changedCurrentLines(
        from previous: CodeEditorGutterViewportSnapshot,
        to current: CodeEditorGutterViewportSnapshot
    ) -> Set<Int> {
        var changedLines = Set<Int>()
        if let previousLine = previous.currentLine {
            changedLines.insert(previousLine)
        }
        if let currentLine = current.currentLine {
            changedLines.insert(currentLine)
        }
        if previous.currentLine == current.currentLine {
            changedLines.removeAll()
        }
        return changedLines
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

    private func scrollPlan(
        from previous: CodeEditorGutterViewportSnapshot,
        to current: CodeEditorGutterViewportSnapshot
    ) -> CodeEditorGutterInvalidationPlan? {
        guard previous.lineCount == current.lineCount else {
            return nil
        }

        guard changedCurrentLines(from: previous, to: current).isEmpty,
              changedDiagnosticLines(from: previous, to: current).isEmpty else {
            return nil
        }

        let previousMetricsByLine = Dictionary(uniqueKeysWithValues: previous.lineMetrics.map { ($0.line, $0) })
        let currentMetricsByLine = Dictionary(uniqueKeysWithValues: current.lineMetrics.map { ($0.line, $0) })
        let previousLines = Set(previousMetricsByLine.keys)
        let currentLines = Set(currentMetricsByLine.keys)
        let overlappingLines = previousLines.intersection(currentLines)
        guard overlappingLines.isEmpty == false else {
            return nil
        }

        let currentOnlyLines = currentLines.subtracting(previousLines)
        guard currentOnlyLines.isEmpty == false else {
            return nil
        }

        let sortedOverlap = overlappingLines.sorted()
        guard let firstLine = sortedOverlap.first,
              let previousMetric = previousMetricsByLine[firstLine],
              let currentMetric = currentMetricsByLine[firstLine] else {
            return nil
        }

        let rawDeltaY = currentMetric.rect.minY - previousMetric.rect.minY
        let deltaY = rawDeltaY.rounded()
        let tolerance: CGFloat = 1.0
        guard abs(deltaY) > tolerance else {
            return nil
        }

        for line in sortedOverlap {
            guard let oldMetric = previousMetricsByLine[line],
                  let newMetric = currentMetricsByLine[line] else {
                return nil
            }

            if abs((newMetric.rect.minY - oldMetric.rect.minY).rounded() - deltaY) > tolerance {
                return nil
            }
            if abs(newMetric.rect.height - oldMetric.rect.height) > tolerance {
                return nil
            }
            if abs((newMetric.baselineY - oldMetric.baselineY).rounded() - deltaY) > tolerance {
                return nil
            }
        }

        return .scroll(
            deltaY: deltaY,
            exposedLines: currentOnlyLines,
            redrawLines: [],
            redrawSeparator: false
        )
    }

    private mutating func attributes(isCurrentLine: Bool) -> [NSAttributedString.Key: Any] {
        let key = AttributeCacheKey(isCurrentLine: isCurrentLine)
        if let cachedAttributes = cachedAttributes[key] {
            return cachedAttributes
        }

        let paragraphStyle: NSParagraphStyle
        if let cachedParagraphStyle {
            paragraphStyle = cachedParagraphStyle
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            cachedParagraphStyle = style.copy() as? NSParagraphStyle
            paragraphStyle = cachedParagraphStyle ?? style
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: isCurrentLine ? .semibold : .regular),
            .foregroundColor: isCurrentLine ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        cachedAttributes[key] = attributes
        return attributes
    }

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
}