import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentLoopToolAuditHookTests {

    @Test func toolAuditHookCreatesToolCallRecordOnWillExecute() async throws {
        let hook = ToolAuditHook(
            sink: nil,
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
            sink: nil,
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

    @Test func toolAuditHookEmitsDedicatedAuditLogForRemovedDebugMetadata() async throws {
        let sink = InMemoryBusinessLogSink()
        let record = ToolCall(toolCallId: "call-3", kind: .execute)
        record.title = "npm run dev"
        record.status = .success
        record.toolDefinitionID = "bash"
        record.toolSchemaVersion = 1
        record.toolExposureSource = "context:workflowWorker"
        record.toolExecutionContext = ToolContext.workflowWorker.rawValue
        record.toolPayloadRef = "payload_123"
        record.toolResultRawChars = 12000
        record.toolResultInjectedChars = 600
        record.toolResultInjectionMode = "referenced"
        record.toolPayloadReadCount = 2
        record.toolPayloadLastReadRange = "lines:201-260"
        record.terminalTaskId = "task-1"
        record.terminalTaskStatus = "runningBackground"
        record.terminalExecutionMode = "background"
        record.terminalPromptSummary = "Listening on http://localhost:3000"
        record.terminalAgentActionsJSON = "[{\"summary\":\"detected prompt\"}]"
        record.memoryRuntimeSnapshotID = "snapshot-1"
        record.memoryRuntimeIntentPhase = "verification"
        record.memoryRuntimeWorkingSetCost = 128
        record.memoryRuntimeDereferenceCount = 3
        record.memoryRuntimeProfiles = ["coding-task"]
        record.memoryRuntimeLayers = ["task"]
        record.memoryRuntimeWarnings = ["truncated"]

        let hook = ToolAuditHook(
            sink: sink,
            createRecord: { _ in record },
            updateRecord: { _ in }
        )
        var context = AgentLoopHookContext.testToolHookContext(toolName: "bash")
        context.toolCallRecord = record

        let result = try await hook.perform(stage: .didExecuteTool, context: context)

        #expect(result == .continue)
        #expect(sink.events.count == 1)
        #expect(sink.events.first?.event == .toolAuditRecorded)
        #expect(sink.events.first?.metadata["toolDefinitionID"] as? String == "bash")
        #expect(sink.events.first?.metadata["toolPayloadRef"] as? String == "payload_123")
        #expect(sink.events.first?.metadata["toolResultRawChars"] as? Int == 12000)
        #expect(sink.events.first?.metadata["toolResultInjectedChars"] as? Int == 600)
        #expect(sink.events.first?.metadata["terminalTaskStatus"] as? String == "runningBackground")
        #expect(sink.events.first?.metadata["memoryRuntimeSnapshotID"] as? String == "snapshot-1")
        #expect(sink.events.first?.metadata["memoryRuntimeProfiles"] as? String == "coding-task")
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