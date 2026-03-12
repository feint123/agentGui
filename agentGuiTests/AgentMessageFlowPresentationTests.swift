import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentMessageFlowPresentationTests {

    @Test func flowSnapshotOrdersMessageRoundAndToolStepsChronologically() async throws {
        let message = AgentMessageFlowFixture.makeChronologicalMessage()

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

        #expect(snapshot.steps.map(AgentMessageFlowFixture.kindLabel) == ["thinking", "read", "edit", "result"])
    }

    @Test func flowSnapshotMarksOnlyActiveStepExpandedWhileRunning() async throws {
        let message = AgentMessageFlowFixture.makeRunningCommandMessage()

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

        #expect(snapshot.steps.filter(\.isExpanded).count == 1)
        let tool = try #require(snapshot.steps.compactMap { step -> ToolStepPresentation? in
            guard case .tool(let value) = step else { return nil }
            return value
        }.last)
        #expect(tool.row.isExpanded == true)
    }

    @Test func flowSnapshotCollapsesCompletedStepsByDefault() async throws {
        let message = AgentMessageFlowFixture.makeCompletedMessage()

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

        #expect(snapshot.steps.allSatisfy { !$0.isExpanded })
    }

    @Test func flowSnapshotPreservesSubagentAsDedicatedStepKind() async throws {
        let message = AgentMessageFlowFixture.makeSubagentMessage(status: .success)

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

        #expect(snapshot.steps.contains { step in
            if case .subagent = step { return true }
            return false
        })
    }

    @Test func flowSnapshotToolLookupDeduplicatesRepeatedToolCallRelationships() async throws {
        let message = Message.agentMessage(text: nil, session: Session(title: "Retry"))
        let round = AgentRound(roundIndex: 0, message: message)
        let tool = ToolCall(toolCallId: "exec-duplicate", kind: .execute, message: message, agentRound: round)
        tool.title = "xcodebuild"
        tool.status = .success

        round.toolCalls = [tool, tool]
        message.agentRounds = [round]

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

        #expect(snapshot.toolCall(for: tool.id) === tool)
    }

    @Test func flowSnapshotProvidesDirectToolCallLookupForRenderedSteps() async throws {
        let message = AgentMessageFlowFixture.makeChronologicalMessage()

        let snapshot = AgentMessageFlowPresentation.snapshot(for: message)
        let toolStep = try #require(snapshot.steps.compactMap { step -> ToolStepPresentation? in
            guard case .tool(let value) = step else { return nil }
            return value
        }.first)

        let toolCall = try #require(snapshot.toolCall(for: toolStep.toolCallID))
        #expect(toolCall.fileName == "ChatView.swift")
    }

    @Test func subagentRowSurfacesAuditSummaryWhenMemoryFieldsExist() async throws {
        let tool = ToolCall(toolCallId: "subagent-memory", kind: .subagent)
        tool.subagentAgentName = "worker"
        tool.storyMemoryTaskType = "verifyContinuity"
        tool.storyMemoryStatus = "ready"
        tool.storyMemoryRiskSummary = "顾沉突然离开王都将与上一章冲突"
        tool.status = .success

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.style == .subagent)
        #expect(row.secondaryText == "顾沉突然离开王都将与上一章冲突")
        #expect(row.tertiaryText == "verifyContinuity · ready")
    }

    @Test func editToolUsesChangeSummaryRowPresentation() async throws {
        let tool = AgentMessageFlowFixture.makeEditToolCall()

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.style == .edit)
        #expect(row.primaryText == "MessageBubbleView.swift")
        #expect(row.secondaryText == "2 处变更")
    }

    @Test func failedExecuteToolExposesFailureSummaryWithoutFullOutput() async throws {
        let tool = AgentMessageFlowFixture.makeFailedCommandCall()

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.style == .execute)
        #expect(row.secondaryText == "duplicate symbol '_main'")
        #expect(row.detailText?.contains("ld: 1 duplicate symbol") == true)
    }

    @Test func runningExecuteToolPreservesTaskStatusMetadata() async throws {
        let tool = ToolCall(toolCallId: "exec-1", kind: .execute)
        tool.title = "npm run dev"
        tool.status = .inProgress
        tool.terminalTaskId = "task-1"
        tool.terminalTaskStatus = "runningBackground"
        tool.terminalExecutionMode = "background"
        tool.terminalPromptSummary = "Listening on http://localhost:3000"

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.statusText == "后台运行中")
        #expect(row.secondaryText == "后台任务")
        #expect(row.tertiaryText == "Listening on http://localhost:3000")
    }

    @Test func managedExecuteDetailSectionsExposeTaskMetadataAndAgentActions() async throws {
        let tool = ToolCall(toolCallId: "exec-2", kind: .execute)
        tool.title = "npm run dev"
        tool.status = .inProgress
        tool.terminalTaskId = "task-2"
        tool.terminalTaskStatus = "waitingForPrompt"
        tool.terminalExecutionMode = "interactive"
        tool.terminalPromptSummary = "Need confirmation to continue"
        tool.terminalOutput = "Project scaffold ready"
        tool.terminalAgentActionsJSON = try AgentMessageFlowFixture.encodedAgentActions([
            TerminalTaskEvent(taskId: "task-2", kind: .promptDetected, summary: "检测到确认提示"),
            TerminalTaskEvent(taskId: "task-2", kind: .userDecisionRequested, summary: "已升级为用户决策")
        ])

        let row = ToolCallRowPresentation.make(for: tool)
        let sections = ToolCallDetailPresentation.sections(for: tool, row: row)

        #expect(sections.map(\.label) == ["命令", "任务状态", "交互摘要", "Agent操作", "输出"])
        #expect(sections[1].text == "交互任务 · 等待输入 · task-2")
        #expect(sections[2].text == "Need confirmation to continue")
        #expect(sections[3].text == "检测到确认提示\n已升级为用户决策")
    }
}

private enum AgentMessageFlowFixture {
    static func kindLabel(_ step: AgentMessageFlowStep) -> String {
        switch step {
        case .result:
            return "result"
        case .thinking:
            return "thinking"
        case .tool(let value):
            switch value.row.style {
            case .read:
                return "read"
            case .edit:
                return "edit"
            case .execute:
                return "execute"
            case .search:
                return "search"
            case .fetch:
                return "fetch"
            case .askUser:
                return "askUser"
            case .subagent:
                return "subagent"
            case .other:
                return "other"
            }
        case .subagent:
            return "subagent"
        }
    }

    static func makeChronologicalMessage() -> Message {
        let message = Message.agentMessage(text: nil, session: Session(title: "Test"))
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = date(0)
        round.thinkingContent = "分析结构"
        round.text = "完成调整"

        let read = ToolCall(toolCallId: "read-1", kind: .read, message: message, agentRound: round)
        read.filePath = "/tmp/ChatView.swift"
        read.status = .success
        read.startTime = date(1)
        read.endTime = date(2)

        let edit = ToolCall(toolCallId: "edit-1", kind: .edit, message: message, agentRound: round)
        edit.filePath = "/tmp/MessageBubbleView.swift"
        edit.diffContent = "--- old\n+++ new\n-foo\n+bar\n-baz\n+qux"
        edit.status = .success
        edit.startTime = date(3)
        edit.endTime = date(4)

        round.toolCalls = [read, edit]
        message.agentRounds = [round]
        message.status = .completed
        return message
    }

    static func makeRunningCommandMessage() -> Message {
        let message = Message.agentMessage(text: nil, session: Session(title: "Running"))
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = date(0)
        round.thinkingContent = "准备执行命令"

        let exec = ToolCall(toolCallId: "exec-1", kind: .execute, message: message, agentRound: round)
        exec.title = "xcodebuild -scheme agentGui"
        exec.terminalOutput = "Compile Swift source..."
        exec.status = .inProgress
        exec.startTime = date(1)

        round.toolCalls = [exec]
        message.agentRounds = [round]
        message.status = .pending
        return message
    }

    static func makeCompletedMessage() -> Message {
        let message = makeChronologicalMessage()
        message.status = .completed
        return message
    }

    static func makeSubagentMessage(status: ToolStatus) -> Message {
        let message = Message.agentMessage(text: nil, session: Session(title: "Subagent"))
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = date(0)

        let subagent = ToolCall(toolCallId: "subagent-1", kind: .subagent, message: message, agentRound: round)
        subagent.subagentAgentName = "Explore"
        subagent.subagentTask = "梳理消息结构"
        subagent.subagentResultKind = "text"
        subagent.status = status
        subagent.startTime = date(1)
        if status != .inProgress {
            subagent.endTime = date(3)
        }

        let subRound = AgentRound(roundIndex: 0)
        subRound.text = "当前消息区更适合做顺序执行流。"
        subagent.subagentRounds = [subRound]

        round.toolCalls = [subagent]
        message.agentRounds = [round]
        message.status = status == .inProgress ? .pending : .completed
        return message
    }

    static func makeEditToolCall() -> ToolCall {
        let tool = ToolCall(toolCallId: "edit-1", kind: .edit)
        tool.filePath = "/tmp/MessageBubbleView.swift"
        tool.diffContent = "--- old\n+++ new\n-old1\n+new1\n-old2\n+new2"
        tool.status = .success
        tool.startTime = date(0)
        tool.endTime = date(1)
        return tool
    }

    static func makeFailedCommandCall() -> ToolCall {
        let tool = ToolCall(toolCallId: "exec-1", kind: .execute)
        tool.title = "xcodebuild -scheme agentGui"
        tool.status = .failed
        tool.startTime = date(0)
        tool.endTime = date(1)
        tool.terminalOutput = "duplicate symbol '_main'\nld: 1 duplicate symbol for architecture arm64"
        return tool
    }

    private static func date(_ second: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + second)
    }

    fileprivate static func encodedAgentActions(_ events: [TerminalTaskEvent]) throws -> String {
        let data = try JSONEncoder().encode(events)
        return String(decoding: data, as: UTF8.self)
    }
}