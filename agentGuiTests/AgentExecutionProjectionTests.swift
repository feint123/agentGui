import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentExecutionProjectionTests {

    @Test func projectionBuildsSettledTranscriptArtifactsAndDigest() async throws {
        let message = AgentExecutionProjectionFixture.makeChronologicalMessage()

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.transcript.answerText == "完成调整")
        #expect(projection.artifacts.changedFiles.map(\.displayName) == ["MessageBubbleView.swift"])
        #expect(projection.digest.editedFileCount == 1)
        #expect(projection.audit.steps.isEmpty == false)
    }

    @Test func projectionBuildsRunningTheaterFromActiveToolCall() async throws {
        let message = AgentExecutionProjectionFixture.makeRunningCommandMessage()

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.header.isLive == true)
        #expect(projection.theater.cards.isEmpty == false)
        #expect(projection.theater.phase == .running)
        #expect(projection.theater.currentActionText == "运行 xcodebuild -scheme agentGui")
        #expect(projection.theater.cards.filter(\.isCurrentAction).map(\.title) == ["运行 xcodebuild -scheme agentGui"])
        #expect(projection.audit.steps.contains { step in
            if case .tool = step { return true }
            return false
        })
    }

    @Test func liveProjectionKeepsRawTraceInAuditWhileTheaterStaysSummarized() async throws {
        let message = AgentExecutionProjectionFixture.makeRunningCommandMessage()

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.transcript.answerText.isEmpty)
        #expect(projection.theater.cards.map(\.title) == ["运行 xcodebuild -scheme agentGui"])
        #expect(projection.audit.steps.map(AgentExecutionProjectionFixture.kindLabel) == ["thinking", "execute"])
    }

    @Test func projectionSeparatesChangedFilesReferencedFilesAndCommandSummaries() async throws {
        let message = AgentExecutionProjectionFixture.makeChronologicalMessage()

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.artifacts.changedFiles.map(\.displayName) == ["MessageBubbleView.swift"])
        #expect(projection.artifacts.referencedFiles.map(\.displayName) == ["ChatView.swift"])
        #expect(projection.artifacts.commandSummaries.isEmpty)
        #expect(projection.digest.verificationSummary == nil)
    }

    @Test func projectionIncludesExecuteCommandSummaryAsArtifact() async throws {
        let message = AgentExecutionProjectionFixture.makeRunningCommandMessage()
        message.agentRounds[0].toolCalls[0].status = .success
        message.agentRounds[0].toolCalls[0].endTime = AgentExecutionProjectionFixture.date(2)
        message.status = .completed
        message.textContent = "命令执行完成"

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.artifacts.commandSummaries.map(\.text) == ["xcodebuild -scheme agentGui"])
    }

    @Test func projectionKeepsRecentlyCompletedNonCommandWorkVisibleWhilePending() async throws {
        let message = AgentExecutionProjectionFixture.makePendingRecentEditMessage()

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.header.isLive == true)
        #expect(projection.theater.phase == .editing)
        #expect(projection.theater.currentActionText == "已修改 MessageBubbleView.swift")
        #expect(projection.theater.cards.map(\.title) == ["已修改 MessageBubbleView.swift", "已检查 ChatView.swift"])
        #expect(projection.theater.cards.allSatisfy { $0.state == .recent })
        #expect(projection.theater.cards.filter(\.isCurrentAction).map(\.title) == ["已修改 MessageBubbleView.swift"])
    }

    @Test func projectionTruncatesActiveCardSubtitleToFiveLines() async throws {
        let message = Message.agentMessage(text: nil, session: Session(title: "Projection Truncation"))
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = AgentExecutionProjectionFixture.date(0)

        let toolCall = ToolCall(toolCallId: "search-1", kind: .search, message: message, agentRound: round)
        toolCall.title = "搜索日志"
        toolCall.status = .inProgress
        toolCall.startTime = AgentExecutionProjectionFixture.date(1)
        toolCall.toolResultSummary = [
            "第 1 行",
            "第 2 行",
            "第 3 行",
            "第 4 行",
            "第 5 行",
            "第 6 行"
        ].joined(separator: "\n")

        round.toolCalls = [toolCall]
        message.agentRounds = [round]
        message.status = .pending

        let projection = AgentExecutionProjection.make(for: message)

        #expect(projection.theater.cards.count == 1)
        #expect(projection.theater.cards[0].subtitle == [
            "第 1 行",
            "第 2 行",
            "第 3 行",
            "第 4 行",
            "第 5 行…"
        ].joined(separator: "\n"))
    }

    @Test func permissionLookupReturnsMostRecentMatchingRequestsFirst() async throws {
        let session = Session.fixture(sessionId: "session-permission", title: "Permission Lookup")
        let message = AgentExecutionProjectionFixture.makeRunningCommandMessage(session: session)
        let round = try #require(message.agentRounds.first)
        let activeCommand = try #require(round.toolCalls.first)

        let reviewTool = ToolCall(toolCallId: "review-1", kind: .read, message: message, agentRound: round)
        reviewTool.filePath = "/tmp/ExecutionTheaterView.swift"
        reviewTool.status = .inProgress
        reviewTool.startTime = AgentExecutionProjectionFixture.date(2)
        round.toolCalls.append(reviewTool)

        let permissionCenter = ACPPermissionCenter()
        permissionCenter.pendingRequests = [
            AgentExecutionProjectionFixture.pendingRequest(
                id: "older-request",
                toolCallID: activeCommand.toolCallId,
                title: "运行命令"
            ),
            AgentExecutionProjectionFixture.pendingRequest(
                id: "newer-request",
                toolCallID: reviewTool.toolCallId,
                title: "读取文件"
            )
        ]

        let flow = AgentMessageFlowPresentation.snapshot(for: message)
        let requests = AgentExecutionPermissionLookup.pendingRequests(for: flow, permissionCenter: permissionCenter)

        #expect(requests.map(\.id) == ["newer-request", "older-request"])
        #expect(requests.map(\.toolCallID) == ["review-1", "exec-1"])
    }

    @Test func permissionLookupIgnoresRequestsWithoutMatchingToolCall() async throws {
        let session = Session.fixture(sessionId: "session-permission", title: "Permission Lookup")
        let message = AgentExecutionProjectionFixture.makeRunningCommandMessage(session: session)
        let permissionCenter = ACPPermissionCenter()
        permissionCenter.pendingRequests = [
            AgentExecutionProjectionFixture.pendingRequest(
                id: "orphan-request",
                toolCallID: "missing-tool",
                title: "孤立请求"
            )
        ]

        let flow = AgentMessageFlowPresentation.snapshot(for: message)
        let requests = AgentExecutionPermissionLookup.pendingRequests(for: flow, permissionCenter: permissionCenter)

        #expect(requests.isEmpty)
    }
}

private enum AgentExecutionProjectionFixture {
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
            case .permission:
                return "permission"
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
        let message = Message.agentMessage(text: nil, session: Session(title: "Projection Test"))
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

    static func makeRunningCommandMessage(session: Session = Session(title: "Projection Running")) -> Message {
        let message = Message.agentMessage(text: nil, session: session)
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = date(0)
        round.thinkingContent = "准备执行命令"

        let exec = ToolCall(toolCallId: "exec-1", kind: .execute, message: message, agentRound: round)
        exec.title = "xcodebuild -scheme agentGui"
        exec.status = .inProgress
        exec.startTime = date(1)
        exec.terminalOutput = "Compile Swift source..."
        round.toolCalls = [exec]

        message.agentRounds = [round]
        message.status = .pending
        return message
    }

    static func makePendingRecentEditMessage() -> Message {
        let message = Message.agentMessage(text: nil, session: Session(title: "Projection Recent"))
        let round = AgentRound(roundIndex: 0, message: message)
        round.timestamp = date(0)
        round.thinkingContent = "检查并修改界面层级"

        let read = ToolCall(toolCallId: "recent-read", kind: .read, message: message, agentRound: round)
        read.filePath = "/tmp/ChatView.swift"
        read.status = .success
        read.startTime = date(1)
        read.endTime = date(2)

        let edit = ToolCall(toolCallId: "recent-edit", kind: .edit, message: message, agentRound: round)
        edit.filePath = "/tmp/MessageBubbleView.swift"
        edit.diffContent = "--- old\n+++ new\n-foo\n+bar"
        edit.status = .success
        edit.startTime = date(3)
        edit.endTime = date(4)

        round.toolCalls = [read, edit]
        message.agentRounds = [round]
        message.status = .pending
        return message
    }

    static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_710_000_000 + offset)
    }

    static func pendingRequest(
        id: String,
        toolCallID: String,
        title: String
    ) -> ACPPermissionCenter.PendingRequest {
        ACPPermissionCenter.PendingRequest(
            id: id,
            source: ACPPermissionCenter.RequestSource(
                providerID: .githubCopilotCLI,
                localSessionID: "session-permission"
            ),
            remoteSessionID: "remote-session",
            toolCallID: toolCallID,
            toolKind: .execute,
            title: title,
            reason: "需要用户批准",
            options: [
                ACPPermissionCenter.PendingOption(
                    id: "allow-once",
                    kind: .allowOnce,
                    name: "允许一次"
                ),
                ACPPermissionCenter.PendingOption(
                    id: "reject-once",
                    kind: .rejectOnce,
                    name: "拒绝"
                )
            ],
            requestedAt: date(10)
        )
    }
}