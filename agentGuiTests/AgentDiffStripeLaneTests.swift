import Testing
import AppKit
@testable import agentGui

@MainActor
struct AgentDiffStripeLaneTests {

    private func makeSnapshot(agentDiff: [Int: CodeEditorGitDiffKind]) -> CodeEditorGutterViewportSnapshot {
        CodeEditorGutterViewportSnapshot(
            lineCount: 20,
            visibleLineRange: 1...20,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: (1...20).map { line in
                CodeEditorVisibleLineMetric(
                    line: line,
                    rect: NSRect(x: 0, y: CGFloat(line - 1) * 18, width: 50, height: 18),
                    baselineY: CGFloat(line - 1) * 18 + 14
                )
            },
            diagnosticsByLine: [:],
            foldableLines: [],
            foldedLines: [],
            gitDiffByLine: [:],
            agentChangeDiffByLine: agentDiff
        )
    }

    @Test func preferredWidthIsConstant() {
        let lane = AgentDiffStripeLane()
        let snap = makeSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 4)
    }

    @Test func hitTestReturnsNil() {
        let lane = AgentDiffStripeLane()
        let snap = makeSnapshot(agentDiff: [5: .added])
        let result = lane.hitTest(
            point: CGPoint(x: 0, y: 0),
            snapshot: snap,
            laneRect: NSRect(x: 0, y: 0, width: 4, height: 400)
        )
        #expect(result == nil)
    }

    @Test func invalidationPlanIsNoneWhenDiffUnchanged() {
        let lane = AgentDiffStripeLane()
        let diff: [Int: CodeEditorGitDiffKind] = [3: .added]
        let prev = makeSnapshot(agentDiff: diff)
        let curr = makeSnapshot(agentDiff: diff)
        let plan = lane.invalidationPlan(from: prev, to: curr)
        if case .none = plan { } else {
            Issue.record("Expected .none but got: \(plan)")
        }
    }

    @Test func invalidationPlanIsLinesWhenDiffChanges() {
        let lane = AgentDiffStripeLane()
        let prev = makeSnapshot(agentDiff: [3: .added, 7: .modified])
        let curr = makeSnapshot(agentDiff: [3: .added, 10: .deleted])  // 7→nil, 10→new
        let plan = lane.invalidationPlan(from: prev, to: curr)
        guard case .lines(let changed) = plan else {
            Issue.record("Expected .lines but got: \(plan)"); return
        }
        #expect(changed.contains(7))   // 旧 modified 行消失
        #expect(changed.contains(10))  // 新 deleted 行出现
        #expect(!changed.contains(3))  // 3 未变化
    }

    @Test func invalidationPlanIsFullWhenNoPrevious() {
        let lane = AgentDiffStripeLane()
        let curr = makeSnapshot(agentDiff: [5: .added])
        let plan = lane.invalidationPlan(from: nil, to: curr)
        if case .full = plan { } else {
            Issue.record("Expected .full but got: \(plan)")
        }
    }

    @Test func idIsAgentDiffStripe() {
        let lane = AgentDiffStripeLane()
        #expect(lane.id == "agentDiffStripe")
    }
}
