import AppKit

final class CodeEditorGutterView: NSRulerView {
    private(set) var lineCount: Int
    private(set) var visibleLineRange: ClosedRange<Int>
    private(set) var currentLine: Int?
    private(set) var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    init(scrollView: NSScrollView, textView: NSTextView, lineCount: Int) {
        self.lineCount = max(lineCount, 1)
        self.visibleLineRange = 1...max(lineCount, 1)
        self.diagnosticsByLine = [:]
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.requiredThickness(for: self.lineCount)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayoutState(
        lineCount: Int,
        visibleLineRange: ClosedRange<Int>,
        currentLine: Int?,
        diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
    ) {
        let previousVisible = self.visibleLineRange
        let previousCurrentLine = self.currentLine
        let previousDiagnostics = self.diagnosticsByLine

        self.lineCount = max(lineCount, 1)
        self.visibleLineRange = visibleLineRange
        self.currentLine = currentLine
        self.diagnosticsByLine = diagnosticsByLine

        let thickness = Self.requiredThickness(for: self.lineCount)
        if ruleThickness != thickness {
            ruleThickness = thickness
        }

        invalidateLine(previousCurrentLine)
        invalidateLine(currentLine)
        invalidateLineRange(previousVisible)
        invalidateLineRange(visibleLineRange)

        let changedDiagnosticLines = Set(previousDiagnostics.keys).symmetricDifference(diagnosticsByLine.keys)
            .union(previousDiagnostics.compactMap { key, value in
                diagnosticsByLine[key] == value ? nil : key
            })
        for line in changedDiagnosticLines {
            invalidateLine(line)
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // NSColor.windowBackgroundColor.setFill()
        // rect.fill()

        for line in visibleLineRange {
            guard let lineRect = lineRect(forLine: line), lineRect.intersects(rect) else {
                continue
            }

            let isCurrentLine = currentLine == line
            if isCurrentLine {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.08).setFill()
                lineRect.fill()
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: isCurrentLine ? .semibold : .regular),
                .foregroundColor: isCurrentLine ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]

            let labelRect = NSRect(x: 0, y: lineRect.minY, width: ruleThickness - 10, height: lineRect.height)
            NSString(string: "\(line)").draw(in: labelRect, withAttributes: attributes)

            if let summary = diagnosticsByLine[line] {
                let markerRect = NSRect(x: ruleThickness - 8, y: lineRect.midY - 2.5, width: 5, height: 5)
                let path = NSBezierPath(ovalIn: markerRect)
                color(for: summary.highestSeverity).setFill()
                path.fill()
            }
        }
    }

    private func invalidateLineRange(_ lineRange: ClosedRange<Int>) {
        for line in lineRange {
            invalidateLine(line)
        }
    }

    private func invalidateLine(_ line: Int?) {
        guard let line,
              let rect = lineRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }

    private func lineRect(forLine line: Int) -> NSRect? {
        guard let textView = clientView as? CodeEditorPlatformTextView,
              let textRect = textView.backgroundRect(forLine: line) else {
            return nil
        }

        let converted = convert(textRect, from: textView)
        return NSRect(x: 0, y: converted.minY, width: ruleThickness, height: converted.height).integral
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

    private static func requiredThickness(for lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        return CGFloat(digits * 8 + 20)
    }
}