import XCTest
@testable import agentGui

final class CompactionCoordinatorTests: XCTestCase {

    // MARK: - Initial State

    func test_initialState_canAttempt_isTrue() async {
        let c = CompactionCoordinator()
        let state = await c.trackingState
        XCTAssertTrue(state.canAttempt)
        XCTAssertFalse(state.isCircuitBreakerTripped)
        XCTAssertFalse(state.isCompacting)
        XCTAssertFalse(state.hasCompacted)
    }

    // MARK: - beginCompaction

    func test_beginCompaction_returnsTrue_andSetsIsCompacting() async {
        let c = CompactionCoordinator()
        let started = await c.beginCompaction()
        XCTAssertTrue(started)
        let state = await c.trackingState
        XCTAssertTrue(state.isCompacting)
    }

    func test_beginCompaction_returnsFalse_whenAlreadyCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        let second = await c.beginCompaction()
        XCTAssertFalse(second)
    }

    // MARK: - recordSuccess

    func test_recordSuccess_resetsFailureCount_andClearsCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        await c.recordFailure()
        _ = await c.beginCompaction()
        await c.recordSuccess()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertFalse(state.isCompacting)
        XCTAssertTrue(state.hasCompacted)
    }

    // MARK: - recordFailure

    func test_recordFailure_incrementsCount_andClearsCompacting() async {
        let c = CompactionCoordinator()
        _ = await c.beginCompaction()
        await c.recordFailure()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.isCompacting)
    }

    // MARK: - Circuit Breaker

    func test_circuitBreaker_tripsAfterThreeFailures() async {
        let c = CompactionCoordinator()
        for _ in 0..<3 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let state = await c.trackingState
        XCTAssertTrue(state.isCircuitBreakerTripped)
        XCTAssertFalse(state.canAttempt)
    }

    func test_circuitBreaker_preventsBeginCompaction_afterTripping() async {
        let c = CompactionCoordinator()
        for _ in 0..<3 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let result = await c.beginCompaction()
        XCTAssertFalse(result)
    }

    func test_circuitBreaker_doesNotTrip_afterTwoFailures() async {
        let c = CompactionCoordinator()
        for _ in 0..<2 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        let state = await c.trackingState
        XCTAssertFalse(state.isCircuitBreakerTripped)
        XCTAssertTrue(state.canAttempt)
    }

    func test_successResetsCircuitBreaker_allowsFurtherAttempts() async {
        let c = CompactionCoordinator()
        // 2 failures then succeed
        for _ in 0..<2 {
            _ = await c.beginCompaction()
            await c.recordFailure()
        }
        _ = await c.beginCompaction()
        await c.recordSuccess()
        // failure count reset to 0
        _ = await c.beginCompaction()
        await c.recordFailure()
        let state = await c.trackingState
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.isCircuitBreakerTripped)
    }
}
