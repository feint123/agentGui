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

    @MainActor
    @Test func reflectionPromptIncludesVerificationStateContext() {
        let text = ClaudeService.makeVerificationReflectionContextTextForTests(
            VerificationState(
                riskScore: 0.72,
                claims: [
                    VerificationClaim(
                        id: "claim-1",
                        text: "targeted tests passed",
                        claimType: .execution,
                        importance: 0.9,
                        verifiability: 0.8,
                        status: .supported,
                        evidenceRefs: ["execution:bash"]
                    )
                ],
                frontier: [
                    VerificationFrontierItem(
                        id: "frontier-1",
                        claimID: "claim-2",
                        claimType: .behavioral,
                        openQuestion: "Runtime behavior is still unverified",
                        recommendedProbe: "run targeted UI check",
                        riskScore: 0.88
                    )
                ],
                repairQueue: ["run targeted UI check"],
                openQuestions: ["No runtime evidence was observed"],
                certificate: ConvergenceCertificate(
                    decision: .revise,
                    supportedClaims: ["targeted tests passed"],
                    contradictedClaims: [],
                    openClaims: ["Runtime behavior is still unverified"],
                    residualRisks: ["Behavioral regression remains untested"],
                    expectedValueOfMoreVerification: 0.72,
                    stopReason: "Need runtime evidence before finishing"
                )
            )
        )

        #expect(text?.contains("Runtime behavior is still unverified") == true)
        #expect(text?.contains("run targeted UI check") == true)
        #expect(text?.contains("Behavioral regression remains untested") == true)
        #expect(text?.contains("Need runtime evidence before finishing") == true)
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