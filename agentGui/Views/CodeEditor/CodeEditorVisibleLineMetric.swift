import CoreGraphics
import Foundation

struct CodeEditorVisibleLineMetric: Equatable, Sendable {
    let line: Int
    let rect: CGRect
    let baselineY: CGFloat
}

typealias CodeEditorGutterLineMetricsSnapshot = CodeEditorGutterViewportSnapshot