import Testing
@testable import agentGui

@MainActor
struct MemoryManagementDashboardTests {
    @Test func cognitionRequiresAttentionWhenOpenFrontiersAndDebtExist() throws {
        let viewModel = RMSCognitionPanelViewModel(
            snapshot: .fixture(
                epistemicState: EpistemicState(
                    frontiers: [
                        FrontierMemory(
                            frontierId: "f-1",
                            goal: "Fix build",
                            openClaim: "Need tool evidence",
                            uncertaintyType: .tooling,
                            impactLevel: .high,
                            suggestedProbe: "Run xcodebuild -list",
                            stopCondition: "Scheme confirmed"
                        )
                    ],
                    verificationDebt: [
                        VerificationDebt(id: "d-1", claim: "Patch works", reason: "No test evidence")
                    ]
                )
            )
        )

        #expect(viewModel.requiresAttention)
        #expect(viewModel.openCognitionItemCount == 2)
    }

    @Test func cognitionIsStableWhenNoOpenFrontiersOrDebtExist() throws {
        let viewModel = RMSCognitionPanelViewModel(snapshot: .fixture())

        #expect(viewModel.requiresAttention == false)
        #expect(viewModel.openCognitionItemCount == 0)
    }
}