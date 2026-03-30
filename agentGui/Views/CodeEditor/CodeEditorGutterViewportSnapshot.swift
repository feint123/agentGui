import Foundation

struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
}

enum CodeEditorGutterInvalidationPlan: Equatable, Sendable {
    case full
    case redraw(lines: Set<Int>, redrawSeparator: Bool)
    case scroll(deltaY: CGFloat, exposedLines: Set<Int>, redrawLines: Set<Int>, redrawSeparator: Bool)
}