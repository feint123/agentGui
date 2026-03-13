import Foundation
import SwiftAnthropic

struct AgentLoopToolExecutionOutcome {
    let result: ToolExecutionResult
    let record: ToolCall
}

struct AgentLoopToolExecutionCoordinator {
    struct Dependencies {
        let runSubagent: (MessageResponse.Content.Input, ToolCall) async -> AgentMessage
        let startWorkflow: (MessageResponse.Content.Input) async -> ToolExecutionResult
        let executeTool: (String, MessageResponse.Content.Input) async -> ToolExecutionResult
        let normalizeBashRequest: (MessageResponse.Content.Input) throws -> BashToolRequest
        let startForegroundBashObservation: (BashToolRequest, ToolCall) async -> Task<Void, Never>?
        let finishBashObservation: (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void
    }

    let dependencies: Dependencies

    func execute(
        pendingTool: AgentLoopPendingTool,
        record: ToolCall,
        interceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)? = nil
    ) async -> AgentLoopToolExecutionOutcome {
        let input = pendingTool.parsedInput

        if let interceptor,
           let intercepted = await interceptor(pendingTool.name, input) {
            return AgentLoopToolExecutionOutcome(result: intercepted, record: record)
        }

        if pendingTool.name == "run_subagent" {
            let agentMessage = await dependencies.runSubagent(input, record)
            record.subagentAgentName = input["agent_name"]?.stringValue
            record.subagentResultKind = agentMessage.content.kindLabel
            if !agentMessage.metadata.isEmpty {
                record.subagentMessageMetadata = agentMessage.metadata
            }
            return AgentLoopToolExecutionOutcome(result: agentMessage.toExecutionResult(), record: record)
        }

        if pendingTool.name == "start_workflow" {
            let result = await dependencies.startWorkflow(input)
            return AgentLoopToolExecutionOutcome(result: result, record: record)
        }

        let isBash = pendingTool.name == "bash"
        let bashRequest = isBash ? (try? dependencies.normalizeBashRequest(input)) : nil
        let shouldObserveForegroundBash = bashRequest?.executionMode == .foreground && bashRequest?.restart != true

        let pollTask = shouldObserveForegroundBash
            ? await dependencies.startForegroundBashObservation(bashRequest!, record)
            : nil

        let result = await dependencies.executeTool(pendingTool.name, input)

        pollTask?.cancel()

        if let bashRequest, isBash, !bashRequest.restart {
            await dependencies.finishBashObservation(bashRequest, record, result)
        }

        return AgentLoopToolExecutionOutcome(result: result, record: record)
    }
}