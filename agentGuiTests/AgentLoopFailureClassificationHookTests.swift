import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct AgentLoopFailureClassificationHookTests {

    @Test func failureClassificationHookRecognizesToolError() async throws {
        let hook = FailureClassificationHook()
        var context = AgentLoopHookContext.testFailureClassificationContext(toolName: "bash")
        context.toolResultText = "command failed"
        context.metadata = ["isError": true]

        let result = try await hook.perform(stage: .classifyFailureTrigger, context: context)

        #expect(result == .failureTrigger(.toolFailure(toolName: "bash", errorText: "command failed")))
    }

    @Test func failureClassificationHookRecognizesReviewerRejection() async throws {
        let hook = FailureClassificationHook()
        var context = AgentLoopHookContext.testFailureClassificationContext(toolName: "run_subagent")
        context.toolInput = ["agent_name": .string("reviewer")]
        context.toolResultText = "{\"status\":\"needs_revision\"}"

        let result = try await hook.perform(stage: .classifyFailureTrigger, context: context)

        #expect(result == .failureTrigger(.reviewerRejection(feedback: context.toolResultText)))
    }

    @Test func failureClassificationHookRecognizesExecutorFailure() async throws {
        let hook = FailureClassificationHook()
        var context = AgentLoopHookContext.testFailureClassificationContext(toolName: "run_subagent")
        context.toolInput = ["agent_name": .string("executor")]
        context.toolResultText = "{\"status\":\"failed\"}"

        let result = try await hook.perform(stage: .classifyFailureTrigger, context: context)

        #expect(result == .failureTrigger(.executorValidationFailure(detail: context.toolResultText)))
    }
}

private extension AgentLoopHookContext {
    static func testFailureClassificationContext(toolName: String) -> AgentLoopHookContext {
        var context = AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "awaitingToolResults"
        )
        context.pendingToolName = toolName
        return context
    }
}