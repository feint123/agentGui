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

    @Test func finalizationGuardHookMapsExecutionGuardRequestToRetryDecision() async throws {
        let hook = FinalizationGuardHook()
        var context = AgentLoopHookContext.testReflectionContext()
        context.metadata = [
            "executionRequirement": ExecutionRequirement(
                requiresExecution: true,
                confidence: 1,
                reason: "must execute"
            ),
            "executionEvidenceKinds": Set<ExecutionEvidenceKind>(),
            "retryCount": 0
        ]

        let result = try await hook.perform(stage: .decideFinalization, context: context)

        #expect(result == .decision(.finalization(.retry(prompt: ExecutionGuard.correctionPrompt))))
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