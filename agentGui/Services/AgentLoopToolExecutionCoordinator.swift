import Foundation
import SwiftAnthropic

struct AgentLoopToolExecutionOutcome {
    let result: ToolExecutionResult
    let record: ToolCall
}

struct AgentLoopToolExecutionCoordinator {
    struct Dependencies {
        let runSubagent: (MessageResponse.Content.Input, ToolCall) async -> AgentMessage
        let requestApprovalIfNeeded: (String, MessageResponse.Content.Input, ToolCall) async -> ToolExecutionResult?
        let executeTool: (String, MessageResponse.Content.Input) async -> ToolExecutionResult
        let normalizeBashRequest: (MessageResponse.Content.Input) throws -> BashToolRequest
        let startForegroundBashObservation: (BashToolRequest, ToolCall) async -> Task<Void, Never>?
        let finishBashObservation: (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void
        var hookPipeline: ToolExecutionHookPipeline?   // F-C3/C4/C5 will register hooks here
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

        let isBash = pendingTool.name == "bash"
        var effectiveInput = input
        var bashRequest = isBash ? (try? dependencies.normalizeBashRequest(input)) : nil

        if isBash,
           var normalizedBashRequest = bashRequest,
           normalizedBashRequest.signal == nil,
           normalizedBashRequest.command != nil,
           normalizedBashRequest.taskId == nil {
            normalizedBashRequest.taskId = record.toolCallId
            bashRequest = normalizedBashRequest
            effectiveInput["task_id"] = .string(record.toolCallId)
            record.terminalTaskId = record.toolCallId
        }

        if let approvalResult = await dependencies.requestApprovalIfNeeded(pendingTool.name, effectiveInput, record) {
            return AgentLoopToolExecutionOutcome(result: approvalResult, record: record)
        }

        // MARK: Hook - preExecute
        if let pipeline = dependencies.hookPipeline {
            let preview = ToolCallPreview(
                toolCallId: record.toolCallId,
                toolName: pendingTool.name,
                input: effectiveInput,
                sessionID: "",
                executionContext: .mainAgent
            )
            let preOutcome = await pipeline.runPreExecute(toolCall: preview)
            if preOutcome.shouldBlock {
                let blockMessage = "[Hook blocked: \(preOutcome.blockReason ?? "no reason")]"
                return AgentLoopToolExecutionOutcome(
                    result: ToolExecutionResult(blockMessage, status: .permissionDenied),
                    record: record
                )
            }
        }

        let shouldObserveForegroundBash = bashRequest?.executionMode == .attached
            && bashRequest?.signal == nil
            && bashRequest?.command != nil

        let pollTask = shouldObserveForegroundBash
            ? await dependencies.startForegroundBashObservation(bashRequest!, record)
            : nil

        let result = await dependencies.executeTool(pendingTool.name, effectiveInput)

        pollTask?.cancel()

        if let bashRequest, isBash {
            await dependencies.finishBashObservation(bashRequest, record, result)
        }

        // MARK: Hook - postExecute / postFailure
        if let pipeline = dependencies.hookPipeline {
            let preview = ToolCallPreview(
                toolCallId: record.toolCallId,
                toolName: pendingTool.name,
                input: effectiveInput,
                sessionID: "",
                executionContext: .mainAgent
            )
            if result.isError {
                let failureAction = await pipeline.runPostFailure(
                    toolCall: preview,
                    error: ToolExecutionHookError(message: result.text)
                )
                switch failureAction {
                case .recover(let recovered):
                    return AgentLoopToolExecutionOutcome(result: recovered, record: record)
                case .appendDiagnostic(let diag):
                    let enhanced = ToolExecutionResult(
                        result.text + "\n" + diag,
                        status: result.status
                    )
                    return AgentLoopToolExecutionOutcome(result: enhanced, record: record)
                case .propagate:
                    break
                }
            } else {
                let runRecord = ToolRunRecord(
                    toolCallId: record.toolCallId,
                    toolName: pendingTool.name,
                    input: effectiveInput,
                    result: result,
                    sessionID: "",
                    executionContext: .mainAgent
                )
                let postAction = await pipeline.runPostExecute(record: runRecord)
                switch postAction {
                case .appendAttachment(let text):
                    record.toolResultSummary = text
                case .rewriteResult(let rewritten):
                    return AgentLoopToolExecutionOutcome(result: rewritten, record: record)
                case .passthrough:
                    break
                }
            }
        }

        return AgentLoopToolExecutionOutcome(result: result, record: record)
    }
}