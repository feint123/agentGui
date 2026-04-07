import AppKit
import Testing
@testable import agentGui

@MainActor
struct GitDiffStripeLaneTests {

    private func makeSnapshot(
        gitDiffByLine: [Int: CodeEditorGitDiffKind],
        visibleRange: ClosedRange<Int> = 1...10
    ) -> CodeEditorGutterViewportSnapshot {
        let lineMetrics = visibleRange.map { line in
            CodeEditorVisibleLineMetric(
                line: line,
                rect: CGRect(x: 0, y: CGFloat((line - 1) * 14), width: 200, height: 14),
                baselineY: CGFloat((line - 1) * 14 + 11)
            )
        }
        return CodeEditorGutterViewportSnapshot(
            lineCount: visibleRange.upperBound,
            visibleLineRange: visibleRange,
            currentLine: nil,
            lineMetrics: lineMetrics,
            diagnosticsByLine: [:],
            gitDiffByLine: gitDiffByLine
        )
    }

    @Test func preferredWidth_is4pt() {
        let lane = GitDiffStripeLane()
        let snapshot = makeSnapshot(gitDiffByLine: [:])
        #expect(lane.preferredWidth(for: snapshot, appearance: nil) == 4)
    }

    @Test func hitTest_alwaysReturnsNil() {
        // diff stripe 不响应点击
        let lane = GitDiffStripeLane()
        let snapshot = makeSnapshot(gitDiffByLine: [1: .added])
        let laneRect = NSRect(x: 0, y: 0, width: 4, height: 140)
        let result = lane.hitTest(point: CGPoint(x: 2, y: 7), snapshot: snapshot, laneRect: laneRect)
        #expect(result == nil)
    }

    @Test func invalidationPlan_emptyToEmpty_isNone() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [:])
        let snap2 = makeSnapshot(gitDiffByLine: [:])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .none = plan { } else { Issue.record("Expected .none") }
    }

    @Test func invalidationPlan_changedLine_linesOnly() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [1: .added])
        let snap2 = makeSnapshot(gitDiffByLine: [1: .modified, 3: .deleted])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .lines(let changed) = plan {
            // 行 1（状态变化）和行 3（新增）都需要重绘
            #expect(changed.contains(1))
            #expect(changed.contains(3))
        } else {
            Issue.record("Expected .lines plan, got: \(plan)")
        }
    }

    @Test func invalidationPlan_sameContent_isNone() {
        let lane = GitDiffStripeLane()
        let snap1 = makeSnapshot(gitDiffByLine: [2: .modified, 5: .added])
        let snap2 = makeSnapshot(gitDiffByLine: [2: .modified, 5: .added])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        if case .none = plan { } else { Issue.record("Expected .none") }
    }

    @Test func invalidationPlan_nilPrevious_isFull() {
        let lane = GitDiffStripeLane()
        let snap = makeSnapshot(gitDiffByLine: [1: .added])
        let plan = lane.invalidationPlan(from: nil, to: snap)
        if case .full = plan { } else { Issue.record("Expected .full") }
    }
}
