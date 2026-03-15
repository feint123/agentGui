import Foundation
import Testing
@testable import agentGui

struct RMSPromptComposerTests {

    @Test func promptComposerRendersOnlyTheExpectedSections() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Fix smoke failure",
            frontiers: [
                .init(
                    id: "frontier-1",
                    goal: "Fix smoke failure",
                    openClaim: "Need current build evidence",
                    suggestedProbe: "Run targeted xcodebuild test",
                    stopCondition: "Targeted test reproduces or clears the issue"
                )
            ],
            constraints: [
                .init(id: "constraint-1", summary: "Inspect before editing", scope: .thread(id: "thread-1"))
            ],
            counterexamples: [
                .init(id: "counterexample-1", summary: "Edit-first caused regression", replacementAction: "Read failure output first")
            ],
            verificationDebts: [
                .init(id: "debt-1", claim: "Patch fixes the issue", reason: "No targeted verification yet")
            ],
            candidateActions: ["Run targeted xcodebuild test"]
        )
        let insights: [RMSInsight] = [
            .constraint(
                id: "constraint-1",
                summary: "Inspect before editing",
                appliesWhen: "coding",
                changesDecision: "block speculative edits"
            )
        ]

        let prompt = RMSPromptComposer().compose(state: state, activatedInsights: insights)

        #expect(prompt.contains("Current Frontiers"))
        #expect(prompt.contains("Constraints"))
        #expect(prompt.contains("Known Counterexamples"))
        #expect(prompt.contains("Verification Debt"))
        #expect(prompt.contains("Preferred Next Actions"))
        #expect(!prompt.contains("Influence Trace"))
        #expect(!prompt.contains("Working Set Cost"))
    }

    @Test func promptComposerMergesTacticInsightsIntoPreferredNextActions() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Fix smoke failure"
        )
        let insights: [RMSInsight] = [
            .tactic(
                id: "tactic-1",
                summary: "Run targeted xcodebuild test first",
                appliesWhen: "xcodebuild",
                changesDecision: "narrow verification scope",
                evidenceRefs: ["round:3"]
            )
        ]

        let prompt = RMSPromptComposer().compose(state: state, activatedInsights: insights)

        #expect(prompt.contains("Preferred Next Actions"))
        #expect(prompt.contains("Run targeted xcodebuild test first"))
    }
}