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
}