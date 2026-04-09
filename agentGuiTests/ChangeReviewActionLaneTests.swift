import Testing
import AppKit
@testable import agentGui

@MainActor
struct ChangeReviewActionLaneTests {

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

    @Test func idIsChangeReviewAction() {
        let lane = ChangeReviewActionLane()
        #expect(lane.id == "changeReviewAction")
    }

    @Test func preferredWidthIsZeroWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 0)
    }

    @Test func preferredWidthIsNonZeroWhenDiffPresent() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [5: .added])
        #expect(lane.preferredWidth(for: snap, appearance: nil) > 0)
    }

    @Test func hitTestReturnsPositiveForAcceptArea() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [1: .added])  // 行 1，y=0..18
        let laneWidth = lane.preferredWidth(for: snap, appearance: nil)
        let laneRect = NSRect(x: 0, y: 0, width: laneWidth, height: 400)

        // ✓ 图标在 lane 左半区（x < laneWidth/2），e.g. x=2
        let acceptPoint = CGPoint(x: laneWidth * 0.25, y: 9)  // 行 1 垂直中心
        let result = lane.hitTest(point: acceptPoint, snapshot: snap, laneRect: laneRect)
        #expect(result != nil)
        if let r = result {
            #expect(r > 0)       // 正数 = accept
            #expect(abs(r) == 1) // 行号 1
        }
    }

    @Test func hitTestReturnsNegativeForRejectArea() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [1: .added])
        let laneWidth = lane.preferredWidth(for: snap, appearance: nil)
        let laneRect = NSRect(x: 0, y: 0, width: laneWidth, height: 400)

        // ✗ 图标在 lane 右半区（x > laneWidth/2）
        let rejectPoint = CGPoint(x: laneWidth * 0.75, y: 9)
        let result = lane.hitTest(point: rejectPoint, snapshot: snap, laneRect: laneRect)
        #expect(result != nil)
        if let r = result {
            #expect(r < 0)       // 负数 = reject
            #expect(abs(r) == 1) // 行号 1
        }
    }

    @Test func hitTestReturnsNilWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeSnapshot(agentDiff: [:])
        let result = lane.hitTest(
            point: CGPoint(x: 2, y: 9),
            snapshot: snap,
            laneRect: NSRect(x: 0, y: 0, width: 30, height: 400)
        )
        #expect(result == nil)
    }

    @Test func invalidationPlanIsNoneWhenDiffUnchanged() {
        let lane = ChangeReviewActionLane()
        let diff: [Int: CodeEditorGitDiffKind] = [5: .modified]
        let prev = makeSnapshot(agentDiff: diff)
        let curr = makeSnapshot(agentDiff: diff)
        let plan = lane.invalidationPlan(from: prev, to: curr)
        if case .none = plan { } else {
            Issue.record("Expected .none but got: \(plan)")
        }
    }
}
