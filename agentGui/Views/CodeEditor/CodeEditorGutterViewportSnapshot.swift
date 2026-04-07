import Foundation

struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    // F12 预留：可折叠行号集合（1-based），F11 阶段始终为空集合
    let foldableLines: Set<Int>
    // F12 预留：已折叠行号集合（1-based），F11 阶段始终为空集合
    let foldedLines: Set<Int>
    // F13 预留：每行 git diff 状态，F11 阶段始终为空字典
    let gitDiffByLine: [Int: CodeEditorGitDiffKind]

    init(
        lineCount: Int,
        visibleLineRange: ClosedRange<Int>,
        currentLine: Int?,
        lineMetrics: [CodeEditorVisibleLineMetric],
        diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary],
        foldableLines: Set<Int> = [],
        foldedLines: Set<Int> = [],
        gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    ) {
        self.lineCount = lineCount
        self.visibleLineRange = visibleLineRange
        self.currentLine = currentLine
        self.lineMetrics = lineMetrics
        self.diagnosticsByLine = diagnosticsByLine
        self.foldableLines = foldableLines
        self.foldedLines = foldedLines
        self.gitDiffByLine = gitDiffByLine
    }
}

/// F13 预留类型（F11 阶段定义但不使用）
enum CodeEditorGitDiffKind: Equatable, Sendable {
    case added
    case modified
    case deleted
}

enum CodeEditorGutterInvalidationPlan: Equatable, Sendable {
    case full
    case redraw(lines: Set<Int>, redrawSeparator: Bool)
    case scroll(deltaY: CGFloat, exposedLines: Set<Int>, redrawLines: Set<Int>, redrawSeparator: Bool)
}