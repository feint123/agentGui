import Foundation
import SwiftAnthropic
import SwiftData

struct AgentLoopToolExecutionOutcome {
    let result: ToolExecutionResult
    let record: ToolCall
}

struct AgentLoopToolExecutionCoordinator {
    struct Dependencies {
        let sessionID: String                          // F-C4: propagated to hook pipeline
        /// S-C2: 父代理 Session 对象（用于写入后台完成通知消息）
        let session: Session?
        /// S-C2: 替代原有 runSubagent 闭包，返回值改为 SubagentLaunchResult（区分同步/异步）
        /// S-F2: 第 6 个参数为可选 ForkParentContext（fork 路径时提供）
        let launchSubagent: (MessageResponse.Content.Input, ToolCall, (String) -> WorkflowRoleDefinition?, SubagentBackgroundExecutor, ModelContext?, ForkParentContext?) async -> SubagentLaunchResult
        let requestApprovalIfNeeded: (String, MessageResponse.Content.Input, ToolCall) async -> ToolExecutionResult?
        let executeTool: (String, MessageResponse.Content.Input) async -> ToolExecutionResult
        let normalizeBashRequest: (MessageResponse.Content.Input) throws -> BashToolRequest
        let startForegroundBashObservation: (BashToolRequest, ToolCall) async -> Task<Void, Never>?
        let finishBashObservation: (BashToolRequest, ToolCall, ToolExecutionResult) async -> Void
        var hookPipeline: ToolExecutionHookPipeline?   // F-C3/C4/C5 will register hooks here
        /// S-C2: 共享后台执行器
        let backgroundExecutor: SubagentBackgroundExecutor
        /// S-C2: ModelContext（用于 SubagentTaskRecord 持久化）
        let modelContext: ModelContext?
    }

    let dependencies: Dependencies

    func execute(
        pendingTool: AgentLoopPendingTool,
        record: ToolCall,
        interceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)? = nil,
        /// S-F2: 当前轮次的 fork 上下文，用于构造 fork child 初始消息
        forkParentContext: ForkParentContext? = nil
    ) async -> AgentLoopToolExecutionOutcome {
        let input = pendingTool.parsedInput

        if let interceptor,
           let intercepted = await interceptor(pendingTool.name, input) {
            return AgentLoopToolExecutionOutcome(result: intercepted, record: record)
        }

        if pendingTool.name == "run_subagent" {
            let launchResult = await dependencies.launchSubagent(
                input,
                record,
                { name in AgentCatalog.shared.find(named: name)?.workflowRoleDefinition },
                dependencies.backgroundExecutor,
                dependencies.modelContext,
                forkParentContext
            )
            // S-F2: for implicit fork, agent_name is absent; fall back to fork type
            let resolvedAgentName = input["agent_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? FORK_SUBAGENT_TYPE
            record.subagentAgentName = resolvedAgentName
            if case .sync(let msg) = launchResult {
                record.subagentResultKind = msg.content.kindLabel
                if !msg.metadata.isEmpty {
                    record.subagentMessageMetadata = msg.metadata
                }
            } else {
                record.subagentResultKind = "async"
            }
            return AgentLoopToolExecutionOutcome(
                result: ToolExecutionResult(launchResult.toolResultText),
                record: record
            )
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
                sessionID: dependencies.sessionID,
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
                sessionID: dependencies.sessionID,
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
                    sessionID: dependencies.sessionID,
                    executionContext: .mainAgent
                )
                let postAction = await pipeline.runPostExecute(record: runRecord)
                switch postAction {
                case .appendAttachment(let text):
                    record.toolResultSummary = text
                case .rewriteResult(let rewritten):
                    // Preserve timeline readability: copy the envelope summary (if any) so that
                    // the execution theater shows e.g. "bash result (24576 chars)" rather than blank.
                    if let summary = rewritten.envelope?.summary {
                        record.toolResultSummary = summary
                    }
                    return AgentLoopToolExecutionOutcome(result: rewritten, record: record)
                case .passthrough:
                    break
                }
            }
        }

        return AgentLoopToolExecutionOutcome(result: result, record: record)
    }
}