import Testing
@testable import agentGui

@MainActor
struct MemoryManagementDashboardTests {
    @Test func governanceHealthBecomesAttentionWhenReviewQueuesExist() throws {
        let viewModel = MemoryManagementViewModel()
        viewModel.pendingConfirmationCount = 2
        viewModel.conflictCount = 1

        #expect(viewModel.governanceHealth == .attention)
        #expect(viewModel.reviewQueueCount == 3)
    }

    @Test func governanceHealthIsHealthyWhenNoPendingItemsExist() throws {
        let viewModel = MemoryManagementViewModel()
        viewModel.pendingConfirmationCount = 0
        viewModel.conflictCount = 0

        #expect(viewModel.governanceHealth == .healthy)
        #expect(viewModel.reviewQueueCount == 0)
    }
}