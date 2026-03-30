import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorGutterRendererTests {
    @Test
    func currentLineChangeInvalidatesOnlyOldAndNewLines() {
        let previous = makeSnapshot(currentLine: 10, diagnostics: [:], visibleRange: 8...18)
        let current = makeSnapshot(currentLine: 11, diagnostics: [:], visibleRange: 8...18)

        var renderer = CodeEditorGutterRenderer()

        #expect(
            renderer.invalidationPlan(from: previous, to: current)
                == .redraw(lines: [10, 11], redrawSeparator: false)
        )
    }

    @Test
    func diagnosticsChangeInvalidatesOnlyChangedLines() {
        let previous = makeSnapshot(currentLine: 10, diagnostics: [:], visibleRange: 8...18)
        let current = makeSnapshot(
            currentLine: 10,
            diagnostics: [12: CodeEditorLineDiagnosticSummary(highestSeverity: .warning, messageCount: 1)],
            visibleRange: 8...18
        )

        var renderer = CodeEditorGutterRenderer()

        #expect(
            renderer.invalidationPlan(from: previous, to: current)
                == .redraw(lines: [12], redrawSeparator: false)
        )
    }

    @Test
    func lineCountDigitBoundaryTriggersWidthRecalculationOnlyWhenNeeded() {
        let twoDigitSnapshot = makeSnapshot(lineCount: 99, visibleRange: 90...99)
        let sameDigitsSnapshot = makeSnapshot(lineCount: 41, visibleRange: 32...41)
        let threeDigitSnapshot = makeSnapshot(lineCount: 100, visibleRange: 90...100)

        var renderer = CodeEditorGutterRenderer()

        let widthAtNinetyNine = renderer.requiredWidth(for: twoDigitSnapshot, appearance: nil)
        let widthAtFortyOne = renderer.requiredWidth(for: sameDigitsSnapshot, appearance: nil)
        let widthAtOneHundred = renderer.requiredWidth(for: threeDigitSnapshot, appearance: nil)

        #expect(widthAtFortyOne == widthAtNinetyNine)
        #expect(widthAtOneHundred > widthAtNinetyNine)
    }

    @Test
    func viewportScrollProducesScrollPlanInsteadOfFullRedraw() {
        let previous = makeSnapshot(visibleRange: 10...20, translatedBy: 0)
        let current = makeSnapshot(visibleRange: 11...21, translatedBy: -14)

        var renderer = CodeEditorGutterRenderer()

        let plan = renderer.invalidationPlan(from: previous, to: current)

        #expect(plan == .scroll(deltaY: -14, exposedLines: [21], redrawLines: [], redrawSeparator: false))
    }

    private func makeSnapshot(
        lineCount: Int = 40,
        currentLine: Int? = 10,
        diagnostics: [Int: CodeEditorLineDiagnosticSummary] = [:],
        visibleRange: ClosedRange<Int>,
        translatedBy: CGFloat = 0
    ) -> CodeEditorGutterViewportSnapshot {
        let lineMetrics = visibleRange.map { line in
            let minY = CGFloat(line * 14) + translatedBy
            return CodeEditorVisibleLineMetric(
                line: line,
                rect: CGRect(x: 0, y: minY, width: 32, height: 14),
                baselineY: minY + 11
            )
        }

        return CodeEditorGutterViewportSnapshot(
            lineCount: lineCount,
            visibleLineRange: visibleRange,
            currentLine: currentLine,
            lineMetrics: lineMetrics,
            diagnosticsByLine: diagnostics
        )
    }
}