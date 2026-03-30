import AppKit

final class CodeEditorGutterView: NSView {
    private weak var textView: CodeEditorPlatformTextView?
    private(set) var lineCount: Int
    private(set) var visibleLineRange: ClosedRange<Int>
    private(set) var currentLine: Int?
    private(set) var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
    var onRequiredWidthChange: (() -> Void)?

    var requiredWidth: CGFloat {
        Self.requiredWidth(for: lineCount)
    }

    override var isFlipped: Bool {
        true
    }

    init(textView: CodeEditorPlatformTextView, lineCount: Int) {
        self.textView = textView
        self.lineCount = max(lineCount, 1)
        self.visibleLineRange = 1...max(lineCount, 1)
        self.currentLine = nil
        self.diagnosticsByLine = [:]
        super.init(frame: .zero)
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
        let previousWidth = requiredWidth
        let previousVisible = self.visibleLineRange
        let previousCurrentLine = self.currentLine
        let previousDiagnostics = self.diagnosticsByLine

        self.lineCount = max(lineCount, 1)
        self.visibleLineRange = visibleLineRange
        self.currentLine = currentLine
        self.diagnosticsByLine = diagnosticsByLine

        if previousWidth != requiredWidth {
            invalidateIntrinsicContentSize()
            onRequiredWidthChange?()
        }

        needsDisplay = true
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

    override func draw(_ dirtyRect: NSRect) {
        // NSColor.windowBackgroundColor.setFill()
        // dirtyRect.fill()

        guard let firstLineRect = lineRect(forLine: visibleLineRange.lowerBound), firstLineRect.intersects(dirtyRect) else {
            return
        }
        let separatorRect = NSRect(x: bounds.width - 1, y: firstLineRect.minY, width: 1, height: dirtyRect.height)
        NSColor.separatorColor.setFill()
        separatorRect.fill()

        for line in visibleLineRange {
            guard let lineRect = lineRect(forLine: line), lineRect.intersects(dirtyRect) else {
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

            let labelRect = NSRect(x: 0, y: lineRect.minY, width: requiredWidth - 10, height: lineRect.height)
            NSString(string: "\(line)").draw(in: labelRect, withAttributes: attributes)

            if let summary = diagnosticsByLine[line] {
                let markerRect = NSRect(x: requiredWidth - 8, y: lineRect.midY - 2.5, width: 5, height: 5)
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
        guard let textView,
              let textRect = textView.backgroundRect(forLine: line) else {
            return nil
        }

        let converted = convert(textRect, from: textView)
        return NSRect(x: 0, y: converted.minY, width: requiredWidth, height: converted.height).integral
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

    private static func requiredWidth(for lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        return CGFloat(digits * 8 + 20)
    }
}