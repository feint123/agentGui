import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct AgentLoopExecutionGuardTests {

    @Test func verifyCompletionWarnsWhenExecutionClaimsLackEvidence() async {
        let service = ClaudeService()
        service.sessionExecutionEvidence["session-1"] = []

        let output = await service.executeVerifyCompletion(
            input: makeVerifyInput(
                verified: ["xcodebuild test passed"],
                notVerified: []
            ),
            sessionId: "session-1",
            claimAssessmentOverride: ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.93,
                rationale: "The statement asserts an executed test result."
            )
        )

        #expect(output.contains("no execution evidence") || output.contains("无执行证据"))
    }

    @Test func verifyCompletionDoesNotWarnWhenExecutionEvidenceExists() async {
        let service = ClaudeService()
        service.sessionExecutionEvidence["session-2"] = [.bash]

        let output = await service.executeVerifyCompletion(
            input: makeVerifyInput(
                verified: ["xcodebuild test passed"],
                notVerified: []
            ),
            sessionId: "session-2",
            claimAssessmentOverride: ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.93,
                rationale: "The statement asserts an executed test result."
            )
        )

        #expect(!output.contains("no execution evidence"))
        #expect(!output.contains("无执行证据"))
    }

    private func makeVerifyInput(
        verified: [String],
        notVerified: [String],
        conclusion: String? = nil
    ) -> MessageResponse.Content.Input {
        var input: MessageResponse.Content.Input = [
            "verified": .array(verified.map(MessageResponse.Content.DynamicContent.string)),
            "not_verified": .array(notVerified.map(MessageResponse.Content.DynamicContent.string))
        ]
        if let conclusion {
            input["conclusion"] = .string(conclusion)
        }
        return input
    }
}