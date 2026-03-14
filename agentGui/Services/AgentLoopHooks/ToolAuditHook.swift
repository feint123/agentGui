import Foundation

struct ToolAuditHook: AgentLoopHook {
    let id = "tool-audit"
    let order = 30
    let kind: AgentLoopHookKind = .mutator
    let isRequired = true

    let sink: BusinessLogSink?
    let createRecord: (AgentLoopHookContext) async throws -> ToolCall
    let updateRecord: (AgentLoopHookContext) async throws -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willExecuteTool || stage == .didExecuteTool
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        switch stage {
        case .willExecuteTool:
            return .toolCallRecord(try await createRecord(context))
        case .didExecuteTool:
            try await updateRecord(context)
            if let record = context.toolCallRecord {
                ToolExecutionBusinessLogger.emitAudit(record: record, context: context, sink: sink)
            }
            return .continue
        default:
            return .continue
        }
    }
}