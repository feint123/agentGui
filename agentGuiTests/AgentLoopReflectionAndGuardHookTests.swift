import Foundation
import Testing
@testable import agentGui

struct AgentLoopReflectionAndGuardHookTests {

    @Test func reflectionHandlingHookReturnsRetryResolution() async throws {
        let hook = ReflectionHandlingHook { _ in
            AgentLoopReflectionResolution(
                shouldRetry: true,
                correctionPrompt: "apply fix"
            )
        }

        let result = try await hook.perform(
            stage: .processReflection,
            context: .testReflectionContext()
        )

        #expect(result == .reflection(.init(shouldRetry: true, correctionPrompt: "apply fix")))
    }

}

private extension AgentLoopHookContext {
    static func testReflectionContext() -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "reflecting"
        )
    }
}