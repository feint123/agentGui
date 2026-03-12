import Foundation
import Testing
@testable import agentGui

@MainActor
struct BashToolCallPresentationTests {

    @Test func runningBackgroundTaskShowsManagedSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-bg", kind: .execute)
        tool.title = "npm run dev"
        tool.status = .inProgress
        tool.terminalExecutionMode = "background"
        tool.terminalTaskStatus = "runningBackground"
        tool.terminalPromptSummary = "http://localhost:3000"

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.statusText == "后台运行中")
        #expect(row.secondaryText == "后台任务")
        #expect(row.tertiaryText == "http://localhost:3000")
    }

    @Test func bubbleHeaderShowsDecisionBadgeForManagedPrompt() async throws {
        let tool = ToolCall(toolCallId: "exec-prompt", kind: .execute)
        tool.title = "npx create-next-app demo"
        tool.status = .inProgress
        tool.terminalExecutionMode = "interactive"
        tool.terminalTaskStatus = "needsUserDecision"
        tool.terminalPromptSummary = "Need permission to overwrite files"

        let row = ToolCallRowPresentation.make(for: tool)
        let badges = ToolCallBubbleHeaderPresentation.badges(for: tool, row: row)

        #expect(badges.map(\.text) == ["交互任务", "等待用户决策"])
    }

    @Test func bubbleHeaderShowsLatestAgentActionSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-auto", kind: .execute)
        tool.title = "npm install"
        tool.status = .inProgress
        tool.terminalExecutionMode = "interactive"
        tool.terminalTaskStatus = "waitingForPrompt"
        tool.terminalAgentActionsJSON = try encodedAgentActions([
            TerminalTaskEvent(taskId: "task-3", kind: .promptDetected, summary: "检测到 yes/no 提示"),
            TerminalTaskEvent(taskId: "task-3", kind: .agentInput, summary: "已自动回复 y")
        ])

        let row = ToolCallRowPresentation.make(for: tool)
        let badges = ToolCallBubbleHeaderPresentation.badges(for: tool, row: row)

        #expect(badges.map(\.text) == ["交互任务", "等待输入", "已自动回复 y"])
    }

    @Test func rowUsesStructuredSummaryWhenLargePayloadMetadataExists() async throws {
        let tool = ToolCall(toolCallId: "exec-large", kind: .execute)
        tool.title = "xcodebuild test"
        tool.status = .success
        tool.toolResultSummary = "bash result: test log summarized"
        tool.toolPayloadRef = "payload_abc"
        tool.terminalOutput = "preview tail"

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.secondaryText == "bash result: test log summarized")
        #expect(row.tertiaryText == "payload_abc")
    }

    private func encodedAgentActions(_ events: [TerminalTaskEvent]) throws -> String {
        let data = try JSONEncoder().encode(events)
        return String(decoding: data, as: UTF8.self)
    }
}