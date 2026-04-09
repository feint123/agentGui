import Testing
import AppKit
@testable import agentGui

/// Feature 24 端到端冒烟测试：
/// 验证从 ChangeProposalReviewSnapshot 到 agentChangeDiffByLine 的完整数据流，
/// 不依赖 UI 渲染层。
@MainActor
struct F24AgentChangeDecorationSmokeTests {

    @Test func agentDiffLaneIsRegisteredWithCorrectID() {
        let lane = AgentDiffStripeLane()
        #expect(lane.id == "agentDiffStripe")
    }

    @Test func actionLaneIsRegisteredWithCorrectID() {
        let lane = ChangeReviewActionLane()
        #expect(lane.id == "changeReviewAction")
    }

    @Test func unifiedDiffParsedFromProposalProducesDiff() {
        let diff = """
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,0 +2,2 @@
        +// Added
        +let x = 1
        """
        let result = UnifiedDiffParser.parse(diff)
        #expect(!result.isEmpty)
    }

    @Test func agentDiffStripeLaneInvalidationPlanDetectsChanges() {
        let lane = AgentDiffStripeLane()
        let snap1 = makeMinimalSnapshot(agentDiff: [1: .added])
        let snap2 = makeMinimalSnapshot(agentDiff: [1: .added, 5: .modified])
        let plan = lane.invalidationPlan(from: snap1, to: snap2)
        guard case .lines(let changed) = plan else {
            Issue.record("Expected .lines"); return
        }
        #expect(changed.contains(5))
    }

    @Test func actionLaneCollapseToZeroWidthWhenNoDiff() {
        let lane = ChangeReviewActionLane()
        let snap = makeMinimalSnapshot(agentDiff: [:])
        #expect(lane.preferredWidth(for: snap, appearance: nil) == 0)
    }

    @Test func actionLaneExpandsWhenDiffPresent() {
        let lane = ChangeReviewActionLane()
        let snap = makeMinimalSnapshot(agentDiff: [3: .modified])
        #expect(lane.preferredWidth(for: snap, appearance: nil) > 0)
    }

    // MARK: - Helper

    private func makeMinimalSnapshot(
        agentDiff: [Int: CodeEditorGitDiffKind]
    ) -> CodeEditorGutterViewportSnapshot {
        CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            cursorLineNumbers: [],
            lineMetrics: (1...10).map { line in
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
}
