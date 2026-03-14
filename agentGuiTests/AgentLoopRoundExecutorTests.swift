import Testing
@testable import agentGui

@MainActor
struct AgentLoopRoundExecutorTests {

    @Test func roundExecutorTypeExistsAsSingleRoundBoundary() {
        let _: AgentLoopRoundExecutor.Type = AgentLoopRoundExecutor.self
    }

    @Test func roundOutcomeCapturesRoundArtifacts() {
        let round = AgentRound(roundIndex: 2)
        let outcome = RoundOutcome(
            roundIndex: 2,
            round: round,
            currentRoundText: "text",
            currentRoundThinking: "thinking",
            pendingTools: [],
            stopReason: "end_turn",
            assistantObjects: [],
            accumulatedTextBeforeRound: "before"
        )

        #expect(outcome.roundIndex == 2)
        #expect(outcome.round === round)
        #expect(outcome.currentRoundText == "text")
        #expect(outcome.currentRoundThinking == "thinking")
        #expect(outcome.stopReason == "end_turn")
        #expect(outcome.accumulatedTextBeforeRound == "before")
    }

    @Test func verificationGateResolutionNeedsMoreEvidenceStoresOpenClaims() {
        let resolution = VerificationGateResolution.needsMoreEvidence(
            openClaims: ["Need direct runtime proof"],
            suggestedProbe: "Call run_subagent verifier"
        )

        switch resolution {
        case .needsMoreEvidence(let openClaims, let suggestedProbe):
            #expect(openClaims == ["Need direct runtime proof"])
            #expect(suggestedProbe == "Call run_subagent verifier")
        case .clearToFinish:
            Issue.record("Expected needsMoreEvidence resolution")
        }
    }

    @Test func verificationGateStaysDisabledWithoutStateOrAutoVerifyRequirement() {
        let enabled = AgentLoopRoundExecutor.shouldEnableVerificationGate(
            toolExecutionContext: .mainAgent,
            accumulatedText: "plain answer",
            verificationState: nil,
            autoVerificationAssessment: nil
        )

        #expect(!enabled)
        #expect(AgentLoopRoundExecutor.makeVerificationResolution(
            verificationState: nil,
            verificationEnabled: enabled
        ) == nil)
    }

    @Test func verificationGateRequiresMoreEvidenceWhenAutoVerifyRequestsIt() {
        let assessment = AutoVerificationAssessment(
            shouldAutoVerify: true,
            taskRequiresToolExecution: true,
            answerClaimsCompletion: true,
            confidence: 0.92,
            rationale: "tool-backed task claims completion"
        )

        let enabled = AgentLoopRoundExecutor.shouldEnableVerificationGate(
            toolExecutionContext: .mainAgent,
            accumulatedText: "done",
            verificationState: nil,
            autoVerificationAssessment: assessment
        )
        let resolution = AgentLoopRoundExecutor.makeVerificationResolution(
            verificationState: nil,
            verificationEnabled: enabled
        )

        #expect(enabled)
        switch resolution {
        case .needsMoreEvidence(let openClaims, let suggestedProbe):
            #expect(openClaims == ["Need direct runtime proof before finishing"])
            #expect(suggestedProbe == "Call run_subagent with verifier before finishing")
        case .clearToFinish:
            Issue.record("Expected needsMoreEvidence resolution")
        case nil:
            Issue.record("Expected verification resolution")
        }
    }
}