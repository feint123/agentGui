import XCTest
@testable import agentGui

@MainActor
final class SessionMemoryHookTests: XCTestCase {

    func test_supports_willFinishRound() {
        let hook = SessionMemoryHook(callback: { _ in })
        XCTAssertTrue(hook.supports(.willFinishRound))
    }

    func test_doesNotSupport_otherStages() {
        let hook = SessionMemoryHook(callback: { _ in })
        let otherStages: [AgentLoopHookStage] = [
            .prepareRun, .willFinishRun, .willStartRound, .didExecuteTool
        ]
        for stage in otherStages {
            XCTAssertFalse(hook.supports(stage), "Should not support \(stage)")
        }
    }

    func test_perform_firesCallback_forMainAgent() async throws {
        let exp = XCTestExpectation(description: "callback fired")
        let hook = SessionMemoryHook(callback: { _ in exp.fulfill() })

        let context = makeTestContext(toolExecutionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        await fulfillment(of: [exp], timeout: 2.0)
    }

    func test_perform_skipsCallback_forSubagent() async throws {
        var callbackFired = false
        let hook = SessionMemoryHook(callback: { _ in callbackFired = true })

        let context = makeTestContext(toolExecutionContext: .subagent)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackFired)
    }

    func test_perform_skipsCallback_forBackgroundTask() async throws {
        var callbackFired = false
        let hook = SessionMemoryHook(callback: { _ in callbackFired = true })

        let context = makeTestContext(toolExecutionContext: .backgroundTask)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackFired)
    }

    func test_hookMetadata() {
        let hook = SessionMemoryHook(callback: { _ in })
        XCTAssertEqual(hook.id, "session-memory")
        XCTAssertEqual(hook.order, 85)
        XCTAssertEqual(hook.kind, .observer)
        XCTAssertFalse(hook.isRequired)
    }

    // MARK: - Helpers

    private func makeTestContext(toolExecutionContext: ToolContext) -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "test-run",
            sessionID: "test-session",
            workflowID: nil,
            executionContext: toolExecutionContext,
            modelId: "claude-sonnet-4-5",
            roundIndex: 2,
            phase: "finalizing"
        )
    }
}
