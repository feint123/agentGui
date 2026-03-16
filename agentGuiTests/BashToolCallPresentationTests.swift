import Foundation
import Testing
@testable import agentGui

@MainActor
struct BashToolCallPresentationTests {

    @Test func runningBackgroundTaskShowsManagedSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-bg", kind: .execute)
        tool.title = "npm run dev"
        tool.status = .inProgress
        tool.terminalExecutionMode = "detached"
        tool.terminalTaskStatus = "running"
        tool.terminalPromptSummary = "http://localhost:3000"

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.statusText == "后台运行中")
        #expect(row.secondaryText == "后台任务")
        #expect(row.tertiaryText == "http://localhost:3000")
    }

    @Test func bubbleHeaderShowsWaitingInputBadgeForAttachedPrompt() async throws {
        let tool = ToolCall(toolCallId: "exec-prompt", kind: .execute)
        tool.title = "npx create-next-app demo"
        tool.status = .inProgress
        tool.terminalExecutionMode = "attached"
        tool.terminalTaskStatus = "waitingForInput"
        tool.terminalPromptSummary = "Need permission to overwrite files"

        let row = ToolCallRowPresentation.make(for: tool)
        let badges = ToolCallBubbleHeaderPresentation.badges(for: tool, row: row)

        #expect(badges.map(\.text) == ["附着任务", "等待输入"])
    }

    @Test func bubbleHeaderShowsLatestAgentActionSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-auto", kind: .execute)
        tool.title = "npm install"
        tool.status = .inProgress
        tool.terminalExecutionMode = "attached"
        tool.terminalTaskStatus = "waitingForInput"
        tool.terminalAgentActionsJSON = try encodedAgentActions([
            TerminalTaskEvent(taskId: "task-3", kind: .promptDetected, summary: "检测到 yes/no 提示"),
            TerminalTaskEvent(taskId: "task-3", kind: .agentInput, summary: "已自动回复 y")
        ])

        let row = ToolCallRowPresentation.make(for: tool)
        let badges = ToolCallBubbleHeaderPresentation.badges(for: tool, row: row)

        #expect(badges.map(\.text) == ["附着任务", "等待输入", "已自动回复 y"])
    }

    @Test func detailPresentationShowsTranscriptAndCompletionReason() async throws {
        let tool = ToolCall(toolCallId: "exec-complete", kind: .execute)
        tool.title = "swift test"
        tool.status = .success
        tool.terminalExecutionMode = "attached"
        tool.terminalTaskStatus = "completed"
        tool.terminalPromptSummary = "All tests passed"
        tool.terminalTranscriptPath = "/tmp/task.log"
        tool.terminalCompletionReason = "exitedZero"

        let row = ToolCallRowPresentation.make(for: tool, isExpanded: true)
        let sections = ToolCallDetailPresentation.sections(for: tool, row: row)

        #expect(sections.contains(where: { $0.label == "Transcript" && $0.text == "/tmp/task.log" }))
        #expect(sections.contains(where: { $0.label == "完成原因" && $0.text == "exitedZero" }))
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

    @Test func stopButtonShowsForRunningManagedExecuteTask() async throws {
        let session = Session.fixture(title: "Bash Session")
        let message = Message.agentFixture(text: "running", session: session, status: .pending)
        let tool = ToolCall(toolCallId: "exec-stop", kind: .execute, message: message)
        tool.title = "npm create vue@latest"
        tool.status = .inProgress
        tool.terminalTaskId = "task-stop"
        tool.terminalTaskStatus = TerminalTaskStatus.waitingForInput.rawValue

        #expect(ToolCallBubbleHeaderPresentation.showsStopButton(for: tool))
    }

    @Test func stopButtonHidesForCompletedExecuteTask() async throws {
        let session = Session.fixture(title: "Bash Session")
        let message = Message.agentFixture(text: "done", session: session)
        let tool = ToolCall(toolCallId: "exec-stop-done", kind: .execute, message: message)
        tool.title = "npm create vue@latest"
        tool.status = .success
        tool.terminalTaskId = "task-stop"
        tool.terminalTaskStatus = TerminalTaskStatus.completed.rawValue

        #expect(!ToolCallBubbleHeaderPresentation.showsStopButton(for: tool))
    }

    private func encodedAgentActions(_ events: [TerminalTaskEvent]) throws -> String {
        let data = try JSONEncoder().encode(events)
        return String(decoding: data, as: UTF8.self)
    }
}