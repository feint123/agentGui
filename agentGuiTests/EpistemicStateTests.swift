import Foundation
import Testing
@testable import agentGui

struct EpistemicStateTests {
    @Test func epistemicStateCarriesFrontiersConstraintsAndDebt() throws {
        let state = EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "f-1",
                    goal: "Fix failing build",
                    openClaim: "Shared scheme may be missing",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "Run xcodebuild -list",
                    stopCondition: "Scheme confirmed"
                )
            ],
            activeConstraints: [
                ConstraintMemory(
                    id: "c-1",
                    summary: "先跑 targeted test 再改实现",
                    scope: .session(id: "s1")
                )
            ],
            candidateActions: ["Run xcodebuild -list"],
            verificationDebt: [
                VerificationDebt(
                    id: "d-1",
                    claim: "Scheme issue",
                    reason: "No direct evidence yet"
                )
            ]
        )

        #expect(state.frontiers.count == 1)
        #expect(state.activeConstraints.count == 1)
        #expect(state.verificationDebt.count == 1)
        #expect(state.candidateActions == ["Run xcodebuild -list"])
    }

    @Test func stableSnapshotTrimsAndFiltersEpistemicCollections() throws {
        let state = EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "  f-1  ",
                    goal: "  Fix failing build  ",
                    openClaim: "  Shared scheme may be missing  ",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "  Run xcodebuild -list  ",
                    stopCondition: "  Scheme confirmed  "
                ),
                FrontierMemory(
                    frontierId: "f-blank",
                    goal: "Fix failing build",
                    openClaim: "   ",
                    uncertaintyType: .tooling,
                    impactLevel: .medium,
                    suggestedProbe: "Inspect scheme",
                    stopCondition: "Evidence gathered"
                )
            ],
            activeConstraints: [
                ConstraintMemory(id: "  c-1  ", summary: "  Inspect before editing  ", scope: .session(id: "s1")),
                ConstraintMemory(id: "c-blank", summary: "   ", scope: .session(id: "s1"))
            ],
            candidateActions: ["  Run xcodebuild -list  ", "   "],
            verificationDebt: [
                VerificationDebt(id: "  d-1  ", claim: "  Scheme issue  ", reason: "  No direct evidence yet  "),
                VerificationDebt(id: "d-blank", claim: "   ", reason: "ignored")
            ],
            activatedMemories: ["  mem-1  ", "   "],
            counterexamples: [
                CounterexampleMemory(id: "  ce-1  ", summary: "  Do not edit before inspect  ", replacementAction: "  Inspect first  "),
                CounterexampleMemory(id: "ce-blank", summary: "   ", replacementAction: "ignored")
            ]
        )

        let snapshot = state.stableSnapshot()

        #expect(snapshot.frontiers.count == 1)
        #expect(snapshot.frontiers.first?.frontierId == "f-1")
        #expect(snapshot.frontiers.first?.goal == "Fix failing build")
        #expect(snapshot.frontiers.first?.openClaim == "Shared scheme may be missing")
        #expect(snapshot.frontiers.first?.suggestedProbe == "Run xcodebuild -list")
        #expect(snapshot.frontiers.first?.stopCondition == "Scheme confirmed")
        #expect(snapshot.activeConstraints.map(\.id) == ["c-1"])
        #expect(snapshot.activeConstraints.map(\.summary) == ["Inspect before editing"])
        #expect(snapshot.candidateActions == ["Run xcodebuild -list"])
        #expect(snapshot.verificationDebt.count == 1)
        #expect(snapshot.verificationDebt.first?.id == "d-1")
        #expect(snapshot.verificationDebt.first?.claim == "Scheme issue")
        #expect(snapshot.verificationDebt.first?.reason == "No direct evidence yet")
        #expect(snapshot.activatedMemories == ["mem-1"])
        #expect(snapshot.counterexamples.count == 1)
        #expect(snapshot.counterexamples.first?.id == "ce-1")
        #expect(snapshot.counterexamples.first?.summary == "Do not edit before inspect")
        #expect(snapshot.counterexamples.first?.replacementAction == "Inspect first")
    }
}