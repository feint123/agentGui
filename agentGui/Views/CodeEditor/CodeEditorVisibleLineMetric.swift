import CoreGraphics
import Foundation

struct CodeEditorVisibleLineMetric: Equatable, Sendable {
    let line: Int
    let rect: CGRect
    let baselineY: CGFloat
}

struct CodeEditorGutterLineMetricsSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
}