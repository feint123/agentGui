import Foundation

struct FailureClassificationHook: AgentLoopHook {
    let id = "failure-classification"
    let order = 40
    let kind: AgentLoopHookKind = .decisionMaker
    let isRequired = false

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .classifyFailureTrigger
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .classifyFailureTrigger else {
            return .continue
        }

        let isError = context.metadata["isError"] as? Bool ?? false
        if isError, let toolName = context.pendingToolName {
            return .failureTrigger(.toolFailure(toolName: toolName, errorText: context.toolResultText))
        }

        guard context.pendingToolName == "run_subagent" else {
            return .continue
        }

        let agentName = context.toolInput["agent_name"]?.stringValue ?? ""
        if agentName == "reviewer" && context.toolResultText.contains("needs_revision") {
            return .failureTrigger(.reviewerRejection(feedback: context.toolResultText))
        }
        if agentName == "executor" &&
            (context.toolResultText.contains("\"status\": \"failed\"") ||
             context.toolResultText.contains("\"status\":\"failed\"")) {
            return .failureTrigger(.executorValidationFailure(detail: context.toolResultText))
        }

        return .continue
    }
}