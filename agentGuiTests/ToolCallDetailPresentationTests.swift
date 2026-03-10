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
}