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
            "agent_name": .string("worker")
        ]

        #expect(ExecutionGuard.evidenceKind(toolName: "bash", input: [:], result: .success("ok")) == .bash)
        #expect(ExecutionGuard.evidenceKind(toolName: "run_subagent", input: toolInput, result: .failure("Error: build failed")) == .executorSubagent)
        #expect(ExecutionGuard.evidenceKind(toolName: "start_workflow", input: [:], result: .success("Workflow completed")) == .workflow)
        #expect(ExecutionGuard.evidenceKind(toolName: "str_replace_based_edit_tool", input: [:], result: .success("edited")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "web_fetch", input: [:], result: .success("content")) == .builtinTool)
        #expect(ExecutionGuard.evidenceKind(toolName: "memory_write", input: [:], result: .success("stored")) == .builtinTool)
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

    @Test func parseAutoVerificationAssessmentHandlesMarkdownFences() {
        let raw = """
        ```json
        {
          "shouldAutoVerify": true,
          "taskRequiresToolExecution": true,
          "answerClaimsCompletion": true,
          "confidence": 0.84,
          "rationale": "The answer claims a file deletion succeeded."
        }
        ```
        """

        let assessment = ExecutionGuard.parseAutoVerificationAssessment(from: raw)

        #expect(assessment?.shouldAutoVerify == true)
        #expect(assessment?.taskRequiresToolExecution == true)
        #expect(assessment?.answerClaimsCompletion == true)
        #expect(assessment?.confidence == 0.84)
    }

    @Test func autoVerificationDecisionUsesModelConfidenceAndAgreement() {
        #expect(ExecutionGuard.shouldAutoVerify(
            AutoVerificationAssessment(
                shouldAutoVerify: true,
                taskRequiresToolExecution: true,
                answerClaimsCompletion: true,
                confidence: 0.91,
                rationale: "The request requires deleting a file and the answer claims success."
            )
        ))
        #expect(!ExecutionGuard.shouldAutoVerify(
            AutoVerificationAssessment(
                shouldAutoVerify: true,
                taskRequiresToolExecution: true,
                answerClaimsCompletion: true,
                confidence: 0.42,
                rationale: "Weak signal."
            )
        ))
        #expect(!ExecutionGuard.shouldAutoVerify(
            AutoVerificationAssessment(
                shouldAutoVerify: true,
                taskRequiresToolExecution: false,
                answerClaimsCompletion: true,
                confidence: 0.95,
                rationale: "No real tool-backed task detected."
            )
        ))
    }

    @Test func autoVerificationPrefilterRecognizesToolBackedMutationTasks() {
        #expect(ExecutionGuard.mayRequireToolBackedVerification(
            userRequest: "Delete /tmp/demo.txt and tell me when it is gone.",
            currentAnswer: "Deleted /tmp/demo.txt successfully."
        ))
        #expect(ExecutionGuard.mayRequireToolBackedVerification(
            userRequest: "请删除 workspace 里的旧文件。",
            currentAnswer: "已经删除完成。"
        ))
        #expect(!ExecutionGuard.mayRequireToolBackedVerification(
            userRequest: "Summarize the README in one sentence.",
            currentAnswer: "Here is the summary."
        ))
    }
}