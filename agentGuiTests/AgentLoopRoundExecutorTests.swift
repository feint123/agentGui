import Testing
import SwiftAnthropic
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

    @Test func verificationGateRequiresMoreEvidenceForProofSeekingRequestsWithoutClassifier() {
        let enabled = AgentLoopRoundExecutor.shouldEnableVerificationGate(
            toolExecutionContext: .mainAgent,
            accumulatedText: "candidate complete",
            verificationState: nil,
            autoVerificationAssessment: nil
        )

        #expect(enabled)
    }

    @Test func verificationGateRequiresMoreEvidenceForImplicitExecutionEvidence() {
        let enabled = AgentLoopRoundExecutor.shouldEnableVerificationGate(
            toolExecutionContext: .mainAgent,
            accumulatedText: "bash round complete",
            verificationState: nil,
            autoVerificationAssessment: nil
        )

        #expect(enabled)
    }

    @Test func reopeningExecutionMarksVerificationStateAsPassToAvoidStaleFailureLoop() {
        let failedState = VerificationState(
            riskScore: 0.72,
            claims: [],
            evidence: [],
            frontier: [
                VerificationFrontierItem(
                    id: "frontier-1",
                    claimID: "claim-1",
                    claimType: .execution,
                    openQuestion: "Need direct runtime proof",
                    recommendedProbe: "Run targeted tests",
                    riskScore: 0.9
                )
            ],
            repairQueue: ["Run targeted tests"],
            openQuestions: ["Need direct runtime proof"],
            certificate: ConvergenceCertificate(
                decision: .revise,
                supportedClaims: [],
                contradictedClaims: [],
                openClaims: ["Need direct runtime proof"],
                residualRisks: ["Verification not rerun yet"],
                expectedValueOfMoreVerification: 0.8,
                stopReason: "Verification failed"
            )
        )

        let reset = AgentLoopRoundExecutor.resetVerificationStateForRepairLoop(failedState)

        #expect(reset.certificate?.decision == .pass)
        #expect(reset.frontier.isEmpty)
        #expect(reset.openQuestions.isEmpty)
        #expect(reset.repairQueue.isEmpty)
        #expect(reset.certificate?.stopReason == "Repair loop reset verification gate")
    }

    @Test func toolExecutionMetadataMarksPayloadReadCalls() {
        let result = ToolExecutionResult.success("payload window")
        let metadata = AgentLoopRoundExecutor.toolExecutionMetadata(
            toolName: "read_tool_payload",
            input: [
                "payload_ref": .string("payload_123"),
                "cursor": .string("lines:5-7")
            ],
            result: result,
            roundIndex: 2,
            claudeService: ClaudeService()
        )

        #expect(metadata["toolPayloadRef"] as? String == "payload_123")
        #expect(metadata["toolPayloadLastReadRange"] as? String == "lines:5-7")
        #expect(metadata["toolPayloadReadCount"] as? Int == 1)
    }
}