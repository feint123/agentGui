import Testing
@testable import agentGui

@MainActor
struct StreamingCharBudgetTrackerTests {

    @Test
    func initialBudgetIsZeroWhenStreamingStarts() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 100)
        #expect(tracker.displayedCharBudget == 0)
        #expect(tracker.isTracking == true)
    }

    @Test
    func advanceIncreasesBudgetByCharsPerFrame() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 100)
        tracker.advance(targetLength: 100)
        #expect(tracker.displayedCharBudget == 8)
        tracker.advance(targetLength: 100)
        #expect(tracker.displayedCharBudget == 16)
    }

    @Test
    func budgetNeverExceedsTargetLength() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 5)
        for _ in 0..<10 { tracker.advance(targetLength: 5) }
        #expect(tracker.displayedCharBudget == 5)
    }

    @Test
    func stopTrackingSnapsBudgetToGiven() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 8)
        tracker.startTracking(targetLength: 200)
        tracker.advance(targetLength: 200)  // budget = 8
        tracker.stopTracking(finalLength: 999)
        #expect(tracker.displayedCharBudget == 999)
        #expect(tracker.isTracking == false)
    }

    @Test
    func targetLengthExpansionIsPickedUpOnNextAdvance() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 50)
        tracker.startTracking(targetLength: 100)
        for _ in 0..<3 { tracker.advance(targetLength: 100) } // budget = 100（上限）
        // 新增了更多文本
        tracker.advance(targetLength: 200)
        #expect(tracker.displayedCharBudget == 150)
    }

    @Test
    func updatingTargetLengthWhileTrackingLetsBudgetContinueFromCurrentProgress() {
        let tracker = StreamingCharBudgetTracker(charsPerFrame: 20)
        tracker.startTracking(targetLength: 40)
        tracker.advance(targetLength: 40)
        #expect(tracker.displayedCharBudget == 20)

        tracker.updateTargetLength(100)
        tracker.advance(targetLength: 100)

        #expect(tracker.displayedCharBudget == 40)
        #expect(tracker.isTracking == true)
    }
}
