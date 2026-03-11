import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolCallDetailPresentationTests {
    @Test func detailSectionsIncludeSnapshotEntryWhenSnapshotIDExists() {
        let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
        toolCall.memoryRuntimeProfiles = ["coding-task"]
        toolCall.memoryRuntimeSnapshotID = "snapshot-1"

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.contains { $0.label == "记忆上下文快照" && $0.text.contains("snapshot-1") })
    }

    @Test func detailSectionsIncludeUnifiedToolMetadata() {
        let toolCall = ToolCall(toolCallId: "tool-2", kind: .execute)
        toolCall.toolDefinitionID = "bash"
        toolCall.toolSchemaVersion = 1
        toolCall.toolExposureSource = "context:workflowWorker"
        toolCall.toolExecutionContext = ToolContext.workflowWorker.rawValue

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.contains { $0.label == "工具定义 ID" && $0.text == "bash" })
        #expect(sections.contains { $0.label == "Schema 版本" && $0.text == "1" })
        #expect(sections.contains { $0.label == "暴露来源" && $0.text == "context:workflowWorker" })
        #expect(sections.contains { $0.label == "执行上下文" && $0.text == ToolContext.workflowWorker.rawValue })
    }
}