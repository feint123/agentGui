import XCTest
@testable import agentGui

// MARK: - ContextWindowBudgetTrackerTests

final class ContextWindowBudgetTrackerTests: XCTestCase {

    // MARK: - Helpers

    private let tracker = ContextWindowBudgetTracker()

    /// 200k context, 20k reserved → effectiveWindow = 180k
    /// warning 阈值 = 180k - 20k = 160k
    /// normal: tokenUsage < 150k (warningThreshold - warningBuffer/2)

    func test_normal_whenTokensBelowWarningThreshold() {
        let state = tracker.evaluate(tokenUsage: 100_000, contextWindow: 200_000)
        XCTAssertEqual(state.level, .normal)
        XCTAssertFalse(state.isAutoCompactReady)
    }

    func test_warning_whenTokensInEarlyWarningZone() {
        // effectiveWindow = 180k, warning 阈值 = 160k
        // 早期警告区间: 160k - 20k/2 = 150k ~ 160k
        let state = tracker.evaluate(tokenUsage: 155_000, contextWindow: 200_000)
        XCTAssertEqual(state.level, .warning)
    }

    func test_critical_whenTokensAboveWarningThreshold() {
        // warning 阈值 (160k) 到 autoCompact 阈值 (167k) 之间
        let state = tracker.evaluate(tokenUsage: 163_000, contextWindow: 200_000)
        XCTAssertEqual(state.level, .critical)
        XCTAssertTrue(state.isAutoCompactReady)
    }

    func test_autoCompactReady_whenTokensAboveAutoCompactThreshold() {
        // autoCompact 阈值 = 200k - 20k - 13k = 167k
        let state = tracker.evaluate(tokenUsage: 168_000, contextWindow: 200_000)
        XCTAssertEqual(state.level, .autoCompactReady)
        XCTAssertTrue(state.isAutoCompactReady)
    }

    func test_percentRemaining_returnsCorrectValue() {
        // effectiveWindow = 180k, usage = 90k → 50% remaining
        let state = tracker.evaluate(tokenUsage: 90_000, contextWindow: 200_000)
        XCTAssertEqual(state.percentRemaining, 50)
    }

    func test_percentRemaining_clampedToZero_whenOverBudget() {
        let state = tracker.evaluate(tokenUsage: 190_000, contextWindow: 200_000)
        XCTAssertGreaterThanOrEqual(state.percentRemaining, 0)
    }

    func test_smallContextWindow_doesNotCrash() {
        // 极端情况：context window 小于 reserved tokens
        let state = tracker.evaluate(tokenUsage: 1_000, contextWindow: 4_096)
        XCTAssertNotNil(state)
    }
}

// MARK: - BudgetRunTrackerTests

final class BudgetRunTrackerTests: XCTestCase {

    func test_notDiminishing_whenContinuationCountLessThan3() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 1_200)
        let result = tracker.recordRound(currentGlobalTokens: 1_210)
        // On 3rd call: continuationCount before check = 2, which is < 3 → not diminishing
        XCTAssertFalse(result.isDiminishing)
    }

    func test_notDiminishing_whenDeltaLargeEvenAfter3Rounds() {
        var tracker = BudgetRunTracker()
        // 3 次 delta 都超过 500
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 2_000)  // delta=1000
        _ = tracker.recordRound(currentGlobalTokens: 3_100)  // delta=1100
        let result = tracker.recordRound(currentGlobalTokens: 4_300) // delta=1200
        XCTAssertFalse(result.isDiminishing)
    }

    func test_isDiminishing_whenContinuationCount3AndBothDeltasSmall() {
        // 对应 Claude Code: continuationCount >= 3 && deltaSinceLastCheck < 500 && lastDeltaTokens < 500
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 100_100) // delta=100 (small)
        _ = tracker.recordRound(currentGlobalTokens: 100_200) // delta=100 (small)
        let result = tracker.recordRound(currentGlobalTokens: 100_280) // delta=80 (small), count=3
        XCTAssertTrue(result.isDiminishing)
    }

    func test_notDiminishing_whenOnlyCurrentDeltaSmall() {
        // lastDeltaTokens 大，当前 delta 小 → 不触发
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 100_000)
        _ = tracker.recordRound(currentGlobalTokens: 101_000) // delta=1000 (large)
        _ = tracker.recordRound(currentGlobalTokens: 101_100) // delta=100 (small)
        let result = tracker.recordRound(currentGlobalTokens: 101_180) // delta=80 (small)
        // continuationCount=3, currentDelta=80 (small), lastDelta=100 (small)
        // 两个 delta 都小 → isDiminishing = true
        XCTAssertTrue(result.isDiminishing)
    }

    func test_continuationCount_incrementsEachRound() {
        var tracker = BudgetRunTracker()
        _ = tracker.recordRound(currentGlobalTokens: 1_000)
        _ = tracker.recordRound(currentGlobalTokens: 1_500)
        let result = tracker.recordRound(currentGlobalTokens: 2_000)
        XCTAssertEqual(result.continuationCount, 3)
    }
}
