import Foundation
import Testing
@testable import agentGui

struct RMSStateTests {

    @Test func stableSnapshotTrimsAndDropsEmptyFields() {
        let state = RMSState(
            taskID: " task-1 ",
            sessionID: " session-1 ",
            threadID: " thread-1 ",
            summary: " Fix the smoke failure ",
            frontiers: [
                .init(
                    id: " frontier-1 ",
                    goal: " Fix build ",
                    openClaim: " Need scheme evidence ",
                    suggestedProbe: " Run xcodebuild -list ",
                    stopCondition: " Scheme confirmed "
                ),
                .init(
                    id: "frontier-empty",
                    goal: "Ignored",
                    openClaim: "   ",
                    suggestedProbe: "Ignored",
                    stopCondition: "Ignored"
                )
            ],
            constraints: [
                .init(id: " constraint-1 ", summary: " Inspect before editing ", scope: .session(id: "session-1")),
                .init(id: "constraint-empty", summary: "   ", scope: .session(id: "session-1"))
            ],
            counterexamples: [
                .init(id: " counterexample-1 ", summary: " Edit-first caused regression ", replacementAction: " Inspect current failure first "),
                .init(id: "counterexample-empty", summary: "   ", replacementAction: "Ignored")
            ],
            verificationDebts: [
                .init(id: " debt-1 ", claim: " Build is green ", reason: " No direct evidence yet "),
                .init(id: "debt-empty", claim: "   ", reason: "Ignored")
            ],
            candidateActions: [" Run targeted test ", "   "],
            stopSignals: [" Evidence collected ", "   "]
        )

        let snapshot = state.stableSnapshot()

        #expect(snapshot.taskID == "task-1")
        #expect(snapshot.summary == "Fix the smoke failure")
        #expect(snapshot.frontiers.count == 1)
        #expect(snapshot.frontiers.first?.openClaim == "Need scheme evidence")
        #expect(snapshot.constraints.count == 1)
        #expect(snapshot.counterexamples.count == 1)
        #expect(snapshot.verificationDebts.count == 1)
        #expect(snapshot.candidateActions == ["Run targeted test"])
        #expect(snapshot.stopSignals == ["Evidence collected"])
    }
}