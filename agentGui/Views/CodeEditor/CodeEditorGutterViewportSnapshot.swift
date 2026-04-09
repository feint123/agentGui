import Foundation

struct CodeEditorGutterViewportSnapshot: Equatable, Sendable {
    let lineCount: Int
    let visibleLineRange: ClosedRange<Int>
    let currentLine: Int?
    /// 多光标行号集合（单光标时 count == 1）
    let cursorLineNumbers: Set<Int>
    let lineMetrics: [CodeEditorVisibleLineMetric]
    let diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]

    // F12 预留：可折叠行号集合（1-based），F11 阶段始终为空集合
    let foldableLines: Set<Int>
    // F12 预留：已折叠行号集合（1-based），F11 阶段始终为空集合
    let foldedLines: Set<Int>
    // F13 预留：每行 git diff 状态，F11 阶段始终为空字典
    let gitDiffByLine: [Int: CodeEditorGitDiffKind]

    // MARK: - Agent Change Diff（F24）
    /// Agent 修改产生的行级 diff，独立于 git diff（不覆盖 gitDiffByLine）。
    /// 来自 ChangeReviewProjectionStore 中当前文件的 ProposedFileChangeSnapshot.unifiedDiff。
    let agentChangeDiffByLine: [Int: CodeEditorGitDiffKind]

    init(
        lineCount: Int,
        visibleLineRange: ClosedRange<Int>,
        currentLine: Int?,
        cursorLineNumbers: Set<Int> = [],
        lineMetrics: [CodeEditorVisibleLineMetric],
        diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary],
        foldableLines: Set<Int> = [],
        foldedLines: Set<Int> = [],
        gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:],
        agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]   // ← 新增，有默认值
    ) {
        self.lineCount = lineCount
        self.visibleLineRange = visibleLineRange
        self.currentLine = currentLine
        self.cursorLineNumbers = cursorLineNumbers.isEmpty ? (currentLine.map { [$0] } ?? []) : cursorLineNumbers
        self.lineMetrics = lineMetrics
        self.diagnosticsByLine = diagnosticsByLine
        self.foldableLines = foldableLines
        self.foldedLines = foldedLines
        self.gitDiffByLine = gitDiffByLine
        self.agentChangeDiffByLine = agentChangeDiffByLine   // ← 新增
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