import Foundation
import Testing
@testable import agentGui

struct RMSSelectorTests {

    @Test func selectorPrefersConstraintThenCounterexampleThenTactic() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Fix smoke"
        )
        let insights: [RMSInsight] = [
            .tactic(
                id: "tactic-1",
                summary: "Use targeted test first",
                appliesWhen: "Swift test triage",
                changesDecision: "narrow the verification scope"
            ),
            .counterexample(
                id: "counterexample-1",
                summary: "Edit-first caused regression",
                appliesWhen: "Build failures without evidence",
                changesDecision: "inspect current state before editing",
                replacementAction: "Read build output first"
            ),
            .constraint(
                id: "constraint-1",
                summary: "Never edit before reading current failure output",
                appliesWhen: "coding",
                changesDecision: "block edit-first behavior"
            )
        ]

        let selected = RMSSelector().select(for: state, insights: insights, budget: 2)

        #expect(selected.map(\.id) == ["constraint-1", "counterexample-1"])
    }

    @Test func selectorPrioritizesInsightsThatMatchCurrentState() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Fix xcodebuild smoke failure",
            candidateActions: ["Run targeted xcodebuild test"]
        )
        let insights: [RMSInsight] = [
            .constraint(
                id: "constraint-creative",
                summary: "Preserve chapter continuity",
                appliesWhen: "creative writing",
                changesDecision: "stay consistent"
            ),
            .tactic(
                id: "tactic-build",
                summary: "Use a targeted xcodebuild invocation first",
                appliesWhen: "xcodebuild",
                changesDecision: "narrow verification scope"
            )
        ]

        let selected = RMSSelector().select(for: state, insights: insights, budget: 1)

        #expect(selected.map(\.id) == ["tactic-build"])
    }
}