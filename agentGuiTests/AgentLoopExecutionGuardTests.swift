import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopExecutionGuardTests {

    @Test func verifyCompletionWarnsWhenExecutionClaimsLackEvidence() async throws {
        let service = ClaudeService()
        let container = try makeContainer()
        let context = container.mainContext
        service.sessionExecutionEvidence["session-1"] = []

        let output = await service.executeVerifyCompletion(
            input: makeVerifyInput(
                verified: ["xcodebuild test passed"],
                notVerified: []
            ),
            sessionId: "session-1",
            modelContext: context,
            claimAssessmentOverride: ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.93,
                rationale: "The statement asserts an executed test result."
            )
        )

        #expect(output.contains("no execution evidence") || output.contains("无执行证据"))
    }

    @Test func verifyCompletionDoesNotWarnWhenExecutionEvidenceExists() async throws {
        let service = ClaudeService()
        let container = try makeContainer()
        let context = container.mainContext
        service.sessionExecutionEvidence["session-2"] = [.bash]

        let output = await service.executeVerifyCompletion(
            input: makeVerifyInput(
                verified: ["xcodebuild test passed"],
                notVerified: []
            ),
            sessionId: "session-2",
            modelContext: context,
            claimAssessmentOverride: ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.93,
                rationale: "The statement asserts an executed test result."
            )
        )

        #expect(!output.contains("no execution evidence"))
        #expect(!output.contains("无执行证据"))
    }

    @Test func verificationFailureTriggerHasDedicatedEvidenceLabel() {
        let trigger = FailureTrigger.verificationFailure(detail: "missing execution evidence")

        #expect(trigger.actionLabel == "verification_failure")
        #expect(trigger.description.contains("missing execution evidence"))
    }

    @Test func verificationFailureTransitionKeepsPendingTriggerUntilReflectionConsumesIt() {
        var loopContext = AgentLoopContext(phase: .verifying)
        loopContext.pendingFailureTrigger = .verificationFailure(detail: "missing execution evidence")

        loopContext.verificationComplete(passed: false)

        #expect(loopContext.phase == .reflecting)
        #expect(loopContext.pendingFailureTrigger == .verificationFailure(detail: "missing execution evidence"))
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

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SessionTaskState.self, configurations: config)
    }
}