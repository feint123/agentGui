import Foundation
import Testing
@testable import agentGui

@MainActor
struct RMSPanelViewModelTests {
    @Test func viewModelProjectsFrontiersCounterexamplesConstraintsAndDebt() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "s1",
            threadID: "thread-1",
            summary: "Fix build",
            frontiers: [
                .init(id: "f-1", goal: "Fix build", openClaim: "Need scheme evidence", suggestedProbe: "Run xcodebuild -list", stopCondition: "Scheme confirmed")
            ],
            constraints: [
                .init(id: "c-1", summary: "Run verification before file edits", scope: .session(id: "s1"))
            ],
            counterexamples: [
                .init(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")
            ],
            verificationDebts: [
                .init(id: "d-1", claim: "Build fix works", reason: "No direct test evidence yet")
            ],
            candidateActions: ["Run xcodebuild -list"]
        )

        let viewModel = RMSPanelViewModel(state: state)

        #expect(viewModel.frontierItems.count == 1)
        #expect(viewModel.counterexampleItems.count == 1)
        #expect(viewModel.constraintItems.count == 1)
        #expect(viewModel.verificationDebtItems.count == 1)
        #expect(viewModel.suggestedActionItems.map(\.summary) == ["Run xcodebuild -list"])
    }

    @Test func viewModelExposesSectionsInUserFacingOrder() {
        let viewModel = RMSPanelViewModel(state: RMSState(taskID: "task-1", sessionID: "s1", threadID: "t1", summary: "Fix build"))

        #expect(viewModel.sectionOrder == [
            .frontiers,
            .counterexamples,
            .constraints,
            .verificationDebt,
            .suggestedActions
        ])
    }

    @Test func viewModelTracksAttentionStateFromFrontiersAndDebt() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Fix build",
            frontiers: [
                .init(id: "f-1", goal: "Fix build", openClaim: "Need scheme evidence", suggestedProbe: "Run xcodebuild -list", stopCondition: "Scheme confirmed")
            ],
            verificationDebts: [
                .init(id: "d-1", claim: "Build fix works", reason: "No direct test evidence yet")
            ]
        )

        let viewModel = RMSPanelViewModel(state: state)

        #expect(viewModel.requiresAttention == true)
        #expect(viewModel.openCognitionItemCount == 2)
    }

    @Test func viewModelExposesVerificationSummaryFromEpistemicState() {
        let state = RMSState(
            taskID: "task-1",
            sessionID: "session-1",
            threadID: "thread-1",
            summary: "Verify completion",
            frontiers: [
                .init(id: "f-1", goal: "Verify completion", openClaim: "Runtime behavior is still unverified", suggestedProbe: "run targeted UI check", stopCondition: "Runtime evidence captured")
            ],
            verificationDebts: [
                .init(id: "d-1", claim: "Runtime behavior is still unverified", reason: "No runtime evidence was observed")
            ]
        )

        let viewModel = RMSPanelViewModel(state: state)

        #expect(viewModel.verificationSummary?.frontierCount == 1)
        #expect(viewModel.verificationSummary?.debtCount == 1)
    }
}