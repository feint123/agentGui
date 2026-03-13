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

    @Test func verifierEvidenceTextPrioritizesHigherRiskRecentEntriesAndSummarizesOmittedOnes() {
        let baseTime = Date(timeIntervalSince1970: 1_000)
        let lowRiskRead = makeToolCall(
            id: "read-1",
            kind: .read,
            title: "查看 README.md",
            secondsFromBase: 0,
            filePath: "/workspace/README.md"
        )
        let lowRiskSearch = makeToolCall(
            id: "search-1",
            kind: .search,
            title: "搜索: docs routing",
            secondsFromBase: 1
        )
        let mediumFetch = makeToolCall(
            id: "fetch-1",
            kind: .fetch,
            title: "获取: https://example.com/spec",
            secondsFromBase: 2
        )
        let highRiskEdit = makeToolCall(
            id: "edit-1",
            kind: .edit,
            title: "编辑 Feature.swift",
            secondsFromBase: 3,
            filePath: "/workspace/Feature.swift"
        )
        let highestRiskExecute = makeToolCall(
            id: "exec-1",
            kind: .execute,
            title: "swift test",
            secondsFromBase: 4,
            command: "swift test --filter FeatureTests",
            status: "completed"
        )

        lowRiskRead.startTime = baseTime.addingTimeInterval(0)
        lowRiskSearch.startTime = baseTime.addingTimeInterval(1)
        mediumFetch.startTime = baseTime.addingTimeInterval(2)
        highRiskEdit.startTime = baseTime.addingTimeInterval(3)
        highestRiskExecute.startTime = baseTime.addingTimeInterval(4)

        let evidenceText = AgentLoopVerificationCoordinator.buildExecutionEvidenceTextForTests(
            executionEvidence: [.builtinTool, .bash],
            toolCalls: [lowRiskRead, lowRiskSearch, mediumFetch, highRiskEdit, highestRiskExecute]
        )

        #expect(evidenceText.contains("execute: swift test"))
        #expect(evidenceText.contains("edit: 编辑 Feature.swift"))
        #expect(evidenceText.contains("fetch: 获取: https://example.com/spec"))
        #expect(!evidenceText.contains("read: 查看 README.md"))
        #expect(!evidenceText.contains("search: 搜索: docs routing"))
        #expect(evidenceText.contains("omitted 2 older/lower-priority evidence entries"))
    }

    @Test func verifierEvidenceTextPrunesNestedSubagentEvidenceUsingTheSamePolicy() {
        let oldRead = makeToolCall(
            id: "nested-read",
            kind: .read,
            title: "查看 Notes.md",
            secondsFromBase: 0,
            filePath: "/workspace/Notes.md"
        )
        let editCall = makeToolCall(
            id: "nested-edit",
            kind: .edit,
            title: "编辑 Feature.swift",
            secondsFromBase: 1,
            filePath: "/workspace/Feature.swift"
        )
        let executeCall = makeToolCall(
            id: "nested-exec",
            kind: .execute,
            title: "swift test",
            secondsFromBase: 2,
            command: "swift test --filter FeatureTests",
            status: "completed"
        )
        let fetchCall = makeToolCall(
            id: "nested-fetch",
            kind: .fetch,
            title: "获取: https://example.com/checklist",
            secondsFromBase: 3
        )

        let subagentRound = AgentRound(roundIndex: 0)
        subagentRound.toolCalls = [oldRead, editCall, executeCall, fetchCall]

        let subagentCall = makeToolCall(id: "subagent", kind: .subagent, title: nil, secondsFromBase: 4)
        subagentCall.subagentAgentName = "worker"
        subagentCall.subagentTask = "Apply and verify the fix"
        subagentCall.subagentRounds = [subagentRound]

        let evidenceText = AgentLoopVerificationCoordinator.buildExecutionEvidenceTextForTests(
            executionEvidence: [.executorSubagent],
            toolCalls: [subagentCall]
        )

        #expect(evidenceText.contains("subagent: worker"))
        #expect(evidenceText.contains("execute: swift test"))
        #expect(evidenceText.contains("edit: 编辑 Feature.swift"))
        #expect(evidenceText.contains("fetch: 获取: https://example.com/checklist"))
        #expect(!evidenceText.contains("read: 查看 Notes.md"))
        #expect(evidenceText.contains("omitted 1 older/lower-priority evidence entries"))
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SessionTaskState.self, configurations: config)
    }

    private func makeToolCall(
        id: String,
        kind: ToolKind,
        title: String?,
        secondsFromBase: TimeInterval,
        filePath: String? = nil,
        command: String? = nil,
        status: String? = nil
    ) -> ToolCall {
        let toolCall = ToolCall(toolCallId: id, kind: kind)
        toolCall.title = title
        toolCall.filePath = filePath
        toolCall.startTime = Date(timeIntervalSince1970: 1_000 + secondsFromBase)
        if let command {
            toolCall.terminalPromptSummary = command
        }
        if let status {
            toolCall.terminalTaskStatus = status
        }
        toolCall.status = .success
        return toolCall
    }
}