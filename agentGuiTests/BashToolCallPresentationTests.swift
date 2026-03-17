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

    @Test func rowProjectsPlannerAndApprovalStates() async throws {
        let tool = ToolCall(toolCallId: "exec-planner", kind: .execute)
        tool.title = "npm create vue@latest demo"
        tool.status = .inProgress
        tool.terminalExecutionMode = "attached"
        tool.terminalTaskStatus = TerminalTaskStatus.awaitingUserApproval.rawValue
        tool.terminalInteractionPhase = TerminalInteractionPhase.awaitingApproval.rawValue
        tool.terminalPlannerSummary = "Select JSX, Router, Pinia, Vitest"
        tool.terminalApprovalPending = true

        let row = ToolCallRowPresentation.make(for: tool)
        let badges = ToolCallBubbleHeaderPresentation.badges(for: tool, row: row)

        #expect(row.statusText == "等待批准")
        #expect(row.secondaryText == "等待批准")
        #expect(row.tertiaryText == "Select JSX, Router, Pinia, Vitest")
        #expect(badges.map(\.text).contains("等待批准"))
        #expect(badges.map(\.text).contains("需要批准"))
    }

    @Test func detailPresentationShowsTakeoverAndPlannerSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-takeover", kind: .execute)
        tool.title = "npm create vue@latest demo"
        tool.status = .inProgress
        tool.terminalExecutionMode = "attached"
        tool.terminalTaskId = "task-takeover"
        tool.terminalTaskStatus = TerminalTaskStatus.userTakeover.rawValue
        tool.terminalInteractionPhase = TerminalInteractionPhase.userTakeover.rawValue
        tool.terminalPlannerSummary = "Planner paused for manual takeover"
        tool.terminalUserTakeoverActive = true

        let row = ToolCallRowPresentation.make(for: tool, isExpanded: true)
        let sections = ToolCallDetailPresentation.sections(for: tool, row: row)

        #expect(sections.contains(where: { $0.label == "交互阶段" && $0.text == "用户接管" }))
        #expect(sections.contains(where: { $0.label == "规划摘要" && $0.text == "Planner paused for manual takeover" }))
        #expect(sections.contains(where: { $0.label == "接管说明" && $0.text.contains("方向键") }))
        #expect(sections.contains(where: { $0.label == "快捷键" && $0.text.contains("Space") && $0.text.contains("Ctrl-C") }))
        #expect(ToolCallBubbleHeaderPresentation.showsStopButton(for: tool))
    }

    @Test func attachedExecuteTaskUsesPrimaryTerminalScreenPresentation() async throws {
        let tool = ToolCall(toolCallId: "exec-screen", kind: .execute)
        tool.title = "npm create vue@latest demo"
        tool.status = .inProgress
        tool.terminalTaskId = "task-screen"
        tool.terminalExecutionMode = TerminalExecutionMode.attached.rawValue
        tool.terminalTaskStatus = TerminalTaskStatus.userTakeover.rawValue

        let row = ToolCallRowPresentation.make(for: tool, isExpanded: true)

        #expect(ToolCallDetailPresentation.showsPrimaryTerminalScreen(for: tool, row: row))
    }

    @Test func detachedExecuteTaskKeepsMetadataFirstPresentation() async throws {
        let tool = ToolCall(toolCallId: "exec-bg-screen", kind: .execute)
        tool.title = "npm run dev"
        tool.status = .inProgress
        tool.terminalTaskId = "task-bg-screen"
        tool.terminalExecutionMode = TerminalExecutionMode.detached.rawValue
        tool.terminalTaskStatus = TerminalTaskStatus.running.rawValue

        let row = ToolCallRowPresentation.make(for: tool, isExpanded: true)

        #expect(!ToolCallDetailPresentation.showsPrimaryTerminalScreen(for: tool, row: row))
    }

    private func encodedAgentActions(_ events: [TerminalTaskEvent]) throws -> String {
        let data = try JSONEncoder().encode(events)
        return String(decoding: data, as: UTF8.self)
    }
}