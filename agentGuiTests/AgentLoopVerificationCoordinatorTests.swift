import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopVerificationCoordinatorTests {

    @Test func updateVerificationAssessmentMergesVerifierFieldsWithoutDiscardingClaims() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = SessionTaskStateStore(modelContext: context)

        try store.saveVerification(
            CompletionVerification(
                verified: ["swift test passed"],
                notVerified: ["manual QA not run"],
                conclusion: "looks ready"
            ),
            for: "session-verify"
        )

        try store.updateVerificationAssessment(
            VerificationAssessmentUpdate(
                passed: false,
                summary: "Missing runtime evidence",
                missingEvidence: ["No command output captured"],
                riskAreas: ["Could regress at runtime"],
                recommendedNextAction: "reflect",
                verifierAgent: "verifier"
            ),
            for: "session-verify"
        )

        let saved = try #require(store.verification(for: "session-verify"))
        #expect(saved.verified == ["swift test passed"])
        #expect(saved.notVerified == ["manual QA not run"])
        #expect(saved.passed == false)
        #expect(saved.summary == "Missing runtime evidence")
        #expect(saved.missingEvidence == ["No command output captured"])
        #expect(saved.verifierAgent == "verifier")
    }

    @Test func verifierPayloadParserAcceptsMarkdownFencedJSON() {
        let text = """
        ```json
        {
          "passed": true,
          "summary": "verification passed",
          "verified_items": ["swift test passed"],
          "failed_items": [],
          "missing_evidence": [],
          "risk_areas": [],
          "recommended_next_action": "finish",
          "confidence": 0.98
        }
        ```
        """

        let payload = AgentLoopVerificationCoordinator.parseVerifierPayloadForTests(from: text)

        #expect(payload?.passed == true)
        #expect(payload?.summary == "verification passed")
        #expect(payload?.verifiedItems == ["swift test passed"])
    }

    @Test func verifierPayloadParserAcceptsProseWrappedJSON() {
        let text = """
        I verified the task and the structured verdict is below.

        {
          "passed": false,
          "summary": "missing runtime evidence",
          "verified_items": ["unit tests passed"],
          "failed_items": [],
          "missing_evidence": ["manual runtime check not observed"],
          "risk_areas": ["runtime behavior"],
          "recommended_next_action": "reflect",
          "confidence": 0.62
        }
        """

        let payload = AgentLoopVerificationCoordinator.parseVerifierPayloadForTests(from: text)

        #expect(payload?.passed == false)
        #expect(payload?.summary == "missing runtime evidence")
        #expect(payload?.missingEvidence == ["manual runtime check not observed"])
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SessionTaskState.self, configurations: config)
    }
}