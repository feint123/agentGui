import Testing
@testable import agentGui

@MainActor
struct MemoryManagementDashboardTests {
    @Test func cognitionRequiresAttentionWhenOpenFrontiersAndDebtExist() throws {
        let viewModel = RMSPanelViewModel(
            state: .fixture(
                frontiers: [
                    .init(id: "f-1", goal: "Fix build", openClaim: "Need tool evidence", suggestedProbe: "Run xcodebuild -list", stopCondition: "Scheme confirmed")
                ],
                verificationDebts: [
                    .init(id: "d-1", claim: "Patch works", reason: "No test evidence")
                ]
            )
        )

        #expect(viewModel.requiresAttention)
        #expect(viewModel.openCognitionItemCount == 2)
    }

    @Test func cognitionIsStableWhenNoOpenFrontiersOrDebtExist() throws {
        let viewModel = RMSPanelViewModel(state: .fixture())

        #expect(viewModel.requiresAttention == false)
        #expect(viewModel.openCognitionItemCount == 0)
    }
}