import XCTest
@testable import agentGui

@MainActor
final class MemoryExtractionHookTests: XCTestCase {

    func test_supports_willFinishRun() {
        let hook = MemoryExtractionHook { _ in }
        XCTAssertTrue(hook.supports(.willFinishRun))
    }

    func test_supports_doesNotSupportOtherStages() {
        let hook = MemoryExtractionHook { _ in }
        let otherStages: [AgentLoopHookStage] = [
            .prepareRun, .didStartRun, .willStartRound,
            .didFinishRun, .willExecuteTool, .didExecuteTool
        ]
        for stage in otherStages {
            XCTAssertFalse(hook.supports(stage), "Should not support \(stage)")
        }
    }

    func test_perform_returnsImmediatelyWithContinue() async throws {
        let expectation = XCTestExpectation(description: "callback eventually called")
        expectation.assertForOverFulfill = true
        let hook = MemoryExtractionHook { _ in expectation.fulfill() }

        let context = makeTestContext(toolExecutionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRun, context: context)

        XCTAssertEqual(result, .continue)
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func test_perform_skipsExtractionForSubagent() async throws {
        var callbackInvoked = false
        let hook = MemoryExtractionHook { _ in callbackInvoked = true }
        let context = makeTestContext(toolExecutionContext: .subagent)

        let result = try await hook.perform(stage: .willFinishRun, context: context)

        XCTAssertEqual(result, .continue)
        // 给足够时间让可能的异步任务运行
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackInvoked, "Subagent run must not trigger extraction")
    }

    // MARK: - Helpers

    private func makeTestContext(
        toolExecutionContext: ToolContext
    ) -> AgentLoopHookContext {
        var ctx = AgentLoopHookContext(
            runID: "test-run",
            sessionID: "test-session",
            workflowID: nil,
            executionContext: toolExecutionContext,
            modelId: "claude-sonnet-4-5",
            roundIndex: 2,
            phase: "finalizing"
        )
        ctx.messagesSnapshot = []
        ctx.metadata = [:]
        return ctx
    }
}
