import Foundation
import Testing
@testable import agentGui

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
}

private enum AgentMessageFlowFixture {
    static func kindLabel(_ step: AgentMessageFlowStep) -> String {
        switch step {
        case .result:
            return "result"
        case .thinking:
            return "thinking"
        case .tool:
            return "tool"
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
}