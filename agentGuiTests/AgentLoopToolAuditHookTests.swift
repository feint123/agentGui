import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentLoopToolAuditHookTests {

    @Test func toolAuditHookCreatesToolCallRecordOnWillExecute() async throws {
        let hook = ToolAuditHook(
            createRecord: { context in
                let record = ToolCall(toolCallId: "call-1", kind: .execute)
                record.title = context.pendingToolName
                record.memoryRuntimeProfiles = ["coding"]
                return record
            },
            updateRecord: { _ in }
        )
        var context = AgentLoopHookContext.testToolHookContext(toolName: "bash")

        let result = try await hook.perform(stage: .willExecuteTool, context: context)

        switch result {
        case .toolCallRecord(let record):
            #expect(record.title == "bash")
            #expect(record.memoryRuntimeProfiles == ["coding"])
        default:
            Issue.record("Expected tool call record result")
        }
    }

    @Test func toolAuditHookUpdatesRecordOnDidExecute() async throws {
        let record = ToolCall(toolCallId: "call-2", kind: .execute)
        let hook = ToolAuditHook(
            createRecord: { _ in record },
            updateRecord: { context in
                context.toolCallRecord?.status = .success
                context.toolCallRecord?.terminalOutput = context.toolResultText
                context.toolCallRecord?.endTime = Date()
            }
        )
        var context = AgentLoopHookContext.testToolHookContext(toolName: "bash")
        context.toolCallRecord = record
        context.toolResultText = "ok"

        let result = try await hook.perform(stage: .didExecuteTool, context: context)

        #expect(result == .continue)
        #expect(record.status == .success)
        #expect(record.terminalOutput == "ok")
        #expect(record.endTime != nil)
    }
}

private extension AgentLoopHookContext {
    static func testToolHookContext(toolName: String) -> AgentLoopHookContext {
        var context = AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "awaitingToolResults"
        )
        context.pendingToolName = toolName
        return context
    }
}