import Testing
@testable import agentGui

@MainActor
struct CodeEditorGutterViewportSnapshotAgentDiffTests {

    @Test func agentChangeDiffByLineDefaultsToEmpty() {
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: [],
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:]
            // agentChangeDiffByLine 未传 → 默认 [:]
        )
        #expect(snapshot.agentChangeDiffByLine.isEmpty)
    }

    @Test func agentChangeDiffByLineRoundTrips() {
        let agentDiff: [Int: CodeEditorGitDiffKind] = [5: .added, 10: .modified, 15: .deleted]
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 20,
            visibleLineRange: 1...20,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: [],
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
        #expect(snapshot.agentChangeDiffByLine == agentDiff)
    }

    @Test func agentChangeDiffEquality() {
        let diff: [Int: CodeEditorGitDiffKind] = [1: .added]
        let s1 = CodeEditorGutterViewportSnapshot(
            lineCount: 5, visibleLineRange: 1...5, currentLine: nil,
            cursorLineNumbers: [], lineMetrics: [], diagnosticsByLine: [:],
            foldableLines: [], foldedLines: [], gitDiffByLine: [:],
            agentChangeDiffByLine: diff
        )
        let s2 = CodeEditorGutterViewportSnapshot(
            lineCount: 5, visibleLineRange: 1...5, currentLine: nil,
            cursorLineNumbers: [], lineMetrics: [], diagnosticsByLine: [:],
            foldableLines: [], foldedLines: [], gitDiffByLine: [:],
            agentChangeDiffByLine: [:]  // 不同
        )
        #expect(s1 != s2)
    }
}
