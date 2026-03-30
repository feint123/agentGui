import AppKit

struct CodeEditorGutterInvalidationSummary: Equatable {
    let redrawnLines: [Int]
    let usedFullRedraw: Bool
    let scrollDeltaY: CGFloat?
}

final class CodeEditorGutterView: NSView {
    private var renderer = CodeEditorGutterRenderer()
    private var snapshot: CodeEditorGutterViewportSnapshot
    private var lineMetricsByLine: [Int: CodeEditorVisibleLineMetric]
    private var cachedRequiredWidth: CGFloat
    var onRequiredWidthChange: (() -> Void)?

    private(set) var lastInvalidationSummary: CodeEditorGutterInvalidationSummary?

    var lineCount: Int {
        snapshot.lineCount
    }

    var visibleLineRange: ClosedRange<Int> {
        snapshot.visibleLineRange
    }

    var currentLine: Int? {
        snapshot.currentLine
    }

    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] {
        snapshot.diagnosticsByLine
    }

    var lineMetrics: [CodeEditorVisibleLineMetric] {
        snapshot.lineMetrics
    }

    var requiredWidth: CGFloat {
        cachedRequiredWidth
    }

    override var isFlipped: Bool {
        true
    }

    init(lineCount: Int) {
        let initialLineCount = max(lineCount, 1)
        self.snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: initialLineCount,
            visibleLineRange: 1...initialLineCount,
            currentLine: nil,
            lineMetrics: [],
            diagnosticsByLine: [:]
        )
        self.lineMetricsByLine = [:]
        self.cachedRequiredWidth = 36
        super.init(frame: .zero)
        self.cachedRequiredWidth = renderer.requiredWidth(for: snapshot, appearance: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLayoutState(_ snapshot: CodeEditorGutterLineMetricsSnapshot) {
        if snapshot.lineMetrics.isEmpty, self.snapshot.lineMetrics.isEmpty == false {
            return
        }

        let previousSnapshot = self.snapshot
        let previousWidth = requiredWidth

        self.snapshot = snapshot
        self.lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })
        let nextWidth = renderer.requiredWidth(for: snapshot, appearance: effectiveAppearance)
        cachedRequiredWidth = nextWidth

        if previousWidth != nextWidth {
            invalidateIntrinsicContentSize()
            onRequiredWidthChange?()
        }

        let plan = renderer.invalidationPlan(from: previousSnapshot, to: snapshot)
        apply(plan)
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer.draw(snapshot: snapshot, in: dirtyRect, bounds: bounds, appearance: effectiveAppearance)
    }

    func clearLastInvalidationSummary() {
        lastInvalidationSummary = nil
    }

    private func apply(_ plan: CodeEditorGutterInvalidationPlan) {
        switch plan {
        case .full:
            needsDisplay = true
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: Array(visibleLineRange),
                usedFullRedraw: true,
                scrollDeltaY: nil
            ))
        case let .redraw(lines, redrawSeparator):
            let redrawnLines = lines.sorted()
            for line in redrawnLines {
                invalidateLine(line)
            }
            if redrawSeparator {
                invalidateSeparator()
            }
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: redrawnLines,
                usedFullRedraw: false,
                scrollDeltaY: nil
            ))
        case let .scroll(deltaY, exposedLines, redrawLines, redrawSeparator):
            scroll(bounds, by: NSSize(width: 0, height: deltaY))
            translateRectsNeedingDisplay(in: bounds, by: NSSize(width: 0, height: deltaY))
            let lines = exposedLines.union(redrawLines).sorted()
            for line in lines {
                invalidateLine(line)
            }
            if redrawSeparator {
                invalidateSeparator()
            }
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: lines,
                usedFullRedraw: false,
                scrollDeltaY: deltaY
            ))
        }
    }

    private func recordInvalidationSummary(_ summary: CodeEditorGutterInvalidationSummary) {
        guard let previous = lastInvalidationSummary else {
            lastInvalidationSummary = summary
            return
        }

        if summary.usedFullRedraw {
            lastInvalidationSummary = summary
            return
        }

        if summary.redrawnLines.isEmpty, summary.scrollDeltaY == nil {
            return
        }

        let mergedLines = Array(Set(previous.redrawnLines).union(summary.redrawnLines)).sorted()
        lastInvalidationSummary = CodeEditorGutterInvalidationSummary(
            redrawnLines: mergedLines,
            usedFullRedraw: previous.usedFullRedraw || summary.usedFullRedraw,
            scrollDeltaY: summary.scrollDeltaY ?? previous.scrollDeltaY
        )
    }

    private func invalidateLine(_ line: Int) {
        guard let rect = lineRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }

    private func invalidateSeparator() {
        let rect = NSRect(x: bounds.width - 1, y: bounds.minY, width: 1, height: bounds.height).integral
        setNeedsDisplay(rect)
    }

    private func lineRect(forLine line: Int) -> NSRect? {
        guard let metric = lineMetricsByLine[line] else {
            return nil
        }

        return NSRect(x: 0, y: metric.rect.minY, width: requiredWidth, height: metric.rect.height).integral
    }
}