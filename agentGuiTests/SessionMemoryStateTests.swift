import XCTest
@testable import agentGui

final class SessionMemoryStateTests: XCTestCase {

    // MARK: - 初始化阈值

    func test_shouldExtract_belowInitThreshold_returnsFalse() async {
        let state = SessionMemoryState()
        // 9,999 tokens < 10,000 init threshold
        let result = await state.shouldExtract(estimatedTokens: 9_999, toolCallsThisRound: 5)
        XCTAssertFalse(result)
    }

    func test_shouldExtract_atInitThreshold_returnsTrue_whenToolCallsMet() async {
        let state = SessionMemoryState()
        // 首次达到 10,000，且 toolCalls >= 3
        let result = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        XCTAssertTrue(result)
    }

    func test_shouldExtract_afterInit_belowTokenUpdateThreshold_returnsFalse() async {
        let state = SessionMemoryState()
        // 第一次触发（初始化）
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 增量 < 5,000（仅增加 4,999）
        let result = await state.shouldExtract(estimatedTokens: 14_999, toolCallsThisRound: 3)
        XCTAssertFalse(result)
    }

    func test_shouldExtract_afterInit_meetsTokenAndToolThreshold_returnsTrue() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 增量 = 5,000，且累计工具调用 >= 3
        let result = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 3)
        XCTAssertTrue(result)
    }

    func test_shouldExtract_noToolCallsInRound_meetsTokenThreshold_returnsTrue() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 无工具调用 + 满足 token 增量 → 对齐 Claude Code "natural conversation break"
        let result = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 0)
        XCTAssertTrue(result)
    }

    func test_recordExtraction_resetsToolCallCounter() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)
        _ = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 15_000)

        // 重置后，工具调用计数从 0 开始，还需要再累计 3 次才满足
        let result = await state.shouldExtract(estimatedTokens: 20_000, toolCallsThisRound: 2)
        XCTAssertFalse(result)
    }

    func test_extractionInProgress_preventsConcurrentExtraction() async {
        let state = SessionMemoryState()
        let acquired = await state.beginExtraction()
        XCTAssertTrue(acquired)
        let rejected = await state.beginExtraction()
        XCTAssertFalse(rejected)
        await state.finishExtraction()
        let acquiredAgain = await state.beginExtraction()
        XCTAssertTrue(acquiredAgain)
    }

    func test_waitForExtraction_returnsWhenCompleted() async {
        let state = SessionMemoryState()
        _ = await state.beginExtraction()

        let waitTask = Task {
            await state.waitForExtraction(timeout: 2.0)
        }

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await state.finishExtraction()
        await waitTask.value
        // 通过不超时即为 pass
    }
}
