import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct ExecutionRequirementTests {

    @Test func ephemeralSystemPromptWrapsPromptInCachedBlock() {
        let system = ClaudeService().makeEphemeralSystemPrompt("You are a coding assistant")

        let encoded = encodedSystemJSON(from: system)
        #expect(encoded.contains("You are a coding assistant"))
        #expect(encoded.contains("cacheControl") || encoded.contains("cache_control"))
        #expect(encoded.contains("ephemeral"))
    }

    @Test func evidenceClassificationRecognizesExecutionTools() {
        let toolInput: MessageResponse.Content.Input = [
            "agent_name": .string("executor")
        ]

        #expect(ExecutionGuard.evidenceKind(toolName: "bash", input: [:], result: .success("ok")) == .bash)
        #expect(ExecutionGuard.evidenceKind(toolName: "run_subagent", input: toolInput, result: .failure("Error: build failed")) == .executorSubagent)
        #expect(ExecutionGuard.evidenceKind(toolName: "start_workflow", input: [:], result: .success("Workflow completed")) == .workflow)
        #expect(ExecutionGuard.evidenceKind(toolName: "str_replace_based_edit_tool", input: [:], result: .success("edited")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "web_fetch", input: [:], result: .success("content")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "memory_write", input: [:], result: .success("stored")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "story_memory_upsert_character", input: [:], result: .success("saved")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "start_workflow", input: [:], result: .failure("Error: failed")) == nil)
        #expect(ExecutionGuard.evidenceKind(toolName: "verify_completion", input: [:], result: .success("ok")) == nil)
        #expect(ExecutionGuard.evidenceKind(toolName: "update_todo_list", input: [:], result: .success("ok")) == nil)
        #expect(ExecutionGuard.evidenceKind(toolName: "read_skill", input: [:], result: .success("ok")) == nil)
    }

    private func encodedSystemJSON(from system: MessageParameter.System?) -> String {
                guard let system else { return "" }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(system),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    @Test func parseClaimAssessmentHandlesMarkdownFences() {
        let raw = """
        ```json
        {
          "claimsExecutionResults": true,
          "confidence": 0.88,
          "rationale": "The statements assert observed test results."
        }
        ```
        """

        let assessment = VerificationEvidenceSupport.parseClaimAssessment(from: raw)

        #expect(assessment?.claimsExecutionResults == true)
        #expect(assessment?.confidence == 0.88)
    }

    @Test func warningDecisionUsesModelConfidence() {
        #expect(ExecutionGuard.shouldWarnForVerificationClaims(
            ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.86,
                rationale: "Observed execution result claim."
            )
        ))
        #expect(!ExecutionGuard.shouldWarnForVerificationClaims(
            ExecutionClaimAssessment(
                claimsExecutionResults: true,
                confidence: 0.41,
                rationale: "Ambiguous claim."
            )
        ))
    }
}