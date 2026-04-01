import XCTest
@testable import agentGui

final class ContextWindowBudgetIntegrationTests: XCTestCase {

    func test_budgetRunTracker_presentInInitialRunState() {
        let state = AgentLoopRunState()
        XCTAssertEqual(state.budgetRunTracker.continuationCount, 0)
    }

    func test_diminishingReturns_detectedAfterThreeSmallDeltas() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 100_050) // delta=50
        _ = tracker.recordRound(currentGlobalTokens: 100_090) // delta=40
        let result = tracker.recordRound(currentGlobalTokens: 100_120) // delta=30, count now=3 at check
        XCTAssertTrue(result.isDiminishing, "连续小 delta 后应触发 diminishing returns")
    }

    func test_budgetRunTracker_canBeStoredInRunState() {
        var state = AgentLoopRunState()
        _ = state.budgetRunTracker.recordRound(currentGlobalTokens: 50_000)
        _ = state.budgetRunTracker.recordRound(currentGlobalTokens: 50_100)
        _ = state.budgetRunTracker.recordRound(currentGlobalTokens: 50_150)
        let result = state.budgetRunTracker.recordRound(currentGlobalTokens: 50_180)
        XCTAssertTrue(result.isDiminishing)
        XCTAssertEqual(state.budgetRunTracker.continuationCount, 4)
    }
}
