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

    @Test func verifierEvidenceTextIncludesRichToolDetails() {
        let editCall = ToolCall(toolCallId: "edit-1", kind: .edit)
        editCall.filePath = "/workspace/AppView.swift"
        editCall.title = "编辑 AppView.swift"
        editCall.diffContent = "--- old\n+++ new"
        editCall.status = .success

        let bashCall = ToolCall(toolCallId: "bash-1", kind: .execute)
        bashCall.title = "npm test"
        bashCall.terminalPromptSummary = "npm test --filter AppViewTests"
        bashCall.terminalTaskStatus = "completed"
        bashCall.terminalOutput = "Executed 12 tests, with 0 failures"
        bashCall.status = .success

        let fetchCall = ToolCall(toolCallId: "fetch-1", kind: .fetch)
        fetchCall.title = "获取: https://example.com/docs"
        fetchCall.toolResultSummary = "Fetched API docs"
        fetchCall.status = .success

        let evidenceText = AgentLoopVerificationCoordinator.buildExecutionEvidenceTextForTests(
            executionEvidence: [.builtinTool, .bash],
            toolCalls: [editCall, bashCall, fetchCall]
        )

        #expect(evidenceText.contains("High-level signals: bash, builtinTool"))
        #expect(evidenceText.contains("path: /workspace/AppView.swift"))
        #expect(evidenceText.contains("command: npm test --filter AppViewTests"))
        #expect(evidenceText.contains("status: completed"))
        #expect(evidenceText.contains("target: https://example.com/docs"))
    }

    @Test func verifierEvidenceTextExpandsNestedSubagentToolActivity() {
        let nestedEdit = ToolCall(toolCallId: "nested-edit", kind: .edit)
        nestedEdit.filePath = "/workspace/Feature.swift"
        nestedEdit.title = "编辑 Feature.swift"
        nestedEdit.status = .success

        let nestedBash = ToolCall(toolCallId: "nested-bash", kind: .execute)
        nestedBash.terminalPromptSummary = "swift test --filter FeatureTests"
        nestedBash.terminalTaskStatus = "completed"
        nestedBash.status = .success

        let subagentRound = AgentRound(roundIndex: 0)
        subagentRound.toolCalls = [nestedEdit, nestedBash]

        let subagentCall = ToolCall(toolCallId: "subagent-1", kind: .subagent)
        subagentCall.subagentAgentName = "worker"
        subagentCall.subagentTask = "Apply the requested fix"
        subagentCall.subagentResultKind = "text"
        subagentCall.subagentRounds = [subagentRound]
        subagentCall.status = .success

        let evidenceText = AgentLoopVerificationCoordinator.buildExecutionEvidenceTextForTests(
            executionEvidence: [.executorSubagent],
            toolCalls: [subagentCall]
        )

        #expect(evidenceText.contains("subagent: worker"))
        #expect(evidenceText.contains("task: Apply the requested fix"))
        #expect(evidenceText.contains("path: /workspace/Feature.swift"))
        #expect(evidenceText.contains("command: swift test --filter FeatureTests"))
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SessionTaskState.self, configurations: config)
    }
}