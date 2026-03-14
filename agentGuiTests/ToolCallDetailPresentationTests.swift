import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolCallDetailPresentationTests {
    @Test func detailSectionsHideRuntimeAuditMetadata() {
        let toolCall = ToolCall(toolCallId: "tool-1", kind: .search)
        toolCall.title = "搜索日志"
        toolCall.toolResultSummary = "找到 3 个相关结果"
        toolCall.toolPayloadRef = "payload_123"
        toolCall.memoryRuntimeProfiles = ["coding-task"]
        toolCall.memoryRuntimeSnapshotID = "snapshot-1"
        toolCall.memoryRuntimeIntentPhase = "verification"
        toolCall.memoryRuntimeWorkingSetCost = 128
        toolCall.memoryRuntimeDereferenceCount = 3
        toolCall.toolDefinitionID = "search"
        toolCall.toolSchemaVersion = 1
        toolCall.toolExposureSource = "context:workflowWorker"
        toolCall.toolExecutionContext = ToolContext.workflowWorker.rawValue

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.map(\.label) == ["目标", "结果摘要"])
        #expect(sections.contains { $0.label == "目标" && $0.text == "payload_123" })
        #expect(sections.contains { $0.label == "结果摘要" && $0.text == "找到 3 个相关结果" })
        #expect(!sections.contains { $0.label == "记忆上下文快照" })
        #expect(!sections.contains { $0.label == "检索意图" })
        #expect(!sections.contains { $0.label == "Working-set Cost" })
        #expect(!sections.contains { $0.label == "Bridge / Dereference" })
        #expect(!sections.contains { $0.label == "工具定义 ID" })
        #expect(!sections.contains { $0.label == "Schema 版本" })
    }

    @Test func executeDetailSectionsOnlyKeepCoreUserFacingInformation() {
        let toolCall = ToolCall(toolCallId: "tool-2", kind: .execute)
        toolCall.title = "npm run dev"
        toolCall.toolResultSummary = "开发服务器已启动"
        toolCall.terminalPromptSummary = "Listening on http://localhost:3000"
        toolCall.terminalTaskStatus = "runningBackground"
        toolCall.terminalExecutionMode = "background"
        toolCall.toolDefinitionID = "bash"
        toolCall.toolSchemaVersion = 1
        toolCall.toolExposureSource = "context:workflowWorker"
        toolCall.toolExecutionContext = ToolContext.workflowWorker.rawValue
        toolCall.terminalAgentActionsJSON = "[{\"taskId\":\"task-1\",\"kind\":\"promptDetected\",\"summary\":\"检测到确认提示\"}]"

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.map(\.label) == ["命令", "当前状态", "结果摘要"])
        #expect(sections.contains { $0.label == "当前状态" && $0.text.contains("后台任务") && $0.text.contains("Listening on http://localhost:3000") })
        #expect(sections.contains { $0.label == "结果摘要" && $0.text == "开发服务器已启动" })
        #expect(!sections.contains { $0.label == "任务状态" })
        #expect(!sections.contains { $0.label == "交互摘要" })
        #expect(!sections.contains { $0.label == "Agent操作" })
        #expect(!sections.contains { $0.label == "工具定义 ID" })
    }

    @Test func fetchDetailSectionsPreferSummaryOverPayloadDiagnostics() {
        let toolCall = ToolCall(toolCallId: "tool-3", kind: .fetch)
        toolCall.filePath = "/tmp/page.html"
        toolCall.toolPayloadRef = "payload_123"
        toolCall.toolResultSummary = "Fetched long page"
        toolCall.toolResultRawChars = 12_000
        toolCall.toolResultInjectedChars = 600
        toolCall.toolResultInjectionMode = "referenced"
        toolCall.toolPayloadReadCount = 2
        toolCall.toolPayloadLastReadRange = "lines:201-260"

        let row = ToolCallRowPresentation.make(for: toolCall)
        let sections = ToolCallDetailPresentation.sections(for: toolCall, row: row)

        #expect(sections.map(\.label) == ["目标", "结果摘要"])
        #expect(sections.contains { $0.label == "目标" && $0.text == "payload_123" })
        #expect(sections.contains { $0.label == "结果摘要" && $0.text == "Fetched long page" })
        #expect(!sections.contains { $0.label == "大载荷引用" })
        #expect(!sections.contains { $0.label == "原始大小" })
        #expect(!sections.contains { $0.label == "注入大小" })
        #expect(!sections.contains { $0.label == "注入模式" })
        #expect(!sections.contains { $0.label == "读取次数" })
        #expect(!sections.contains { $0.label == "最近读取区间" })
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