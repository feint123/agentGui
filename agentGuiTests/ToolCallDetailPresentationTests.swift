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

    @Test func detailSectionsIncludeLargeTextPayloadMetadata() {
        let toolCall = ToolCall(toolCallId: "tool-3", kind: .fetch)
        toolCall.toolPayloadRef = "payload_123"
        toolCall.toolResultSummary = "Fetched long page"
        toolCall.toolResultRawChars = 12_000
        toolCall.toolResultInjectedChars = 600
        toolCall.toolResultInjectionMode = "referenced"
        toolCall.toolPayloadReadCount = 2
        toolCall.toolPayloadLastReadRange = "lines:201-260"

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.contains { $0.label == "大载荷引用" && $0.text == "payload_123" })
        #expect(sections.contains { $0.label == "原始大小" && $0.text == "12000 chars" })
        #expect(sections.contains { $0.label == "注入大小" && $0.text == "600 chars" })
        #expect(sections.contains { $0.label == "注入模式" && $0.text == "referenced" })
        #expect(sections.contains { $0.label == "读取次数" && $0.text == "2" })
        #expect(sections.contains { $0.label == "最近读取区间" && $0.text == "lines:201-260" })
    }

    @Test func verifierSubagentDetailSectionsIncludeVerificationVerdict() {
        let toolCall = ToolCall(toolCallId: "tool-4", kind: .subagent)
        toolCall.subagentAgentName = "verifier"
        toolCall.subagentTask = "验证实现结果"
        toolCall.subagentMessageMetadata = [
            "verificationPassed": "false",
            "verificationSummary": "missing runtime evidence"
        ]

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.contains { $0.label == "验证结果" && $0.text == "验证失败" })
        #expect(sections.contains { $0.label == "验证摘要" && $0.text == "missing runtime evidence" })
    }
}