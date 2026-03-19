import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatMessageListSnapshotBuilderTests {

    @Test func builderCreatesSnapshotsForEachMessageOnInitialBuild() async throws {
        let session = Session(title: "Build")
        let user = Message.userMessage(text: "first", session: session)
        let agent = Message.agentMessage(text: "second", session: session)

        let snapshot = ChatMessageListSnapshotBuilder.build(
            messages: [user, agent],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: [:]
        )

        #expect(snapshot.rows.map { $0.id } == [user.id, agent.id])
        #expect(snapshot.cache.count == 2)
    }

    @Test func builderReusesUnchangedRowsWhenStreamingTailChanges() async throws {
        let session = Session(title: "Reuse")
        let first = Message.userMessage(text: "first", session: session)
        let second = Message.agentMessage(text: "tail v1", session: session)

        let initial = ChatMessageListSnapshotBuilder.build(
            messages: [first, second],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: [:]
        )

        second.textContent = "tail v2"

        let updated = ChatMessageListSnapshotBuilder.build(
            messages: [first, second],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: initial.cache
        )

        #expect(initial.cachedEntry(for: first.id) === updated.cachedEntry(for: first.id))
        #expect(initial.cachedEntry(for: second.id) !== updated.cachedEntry(for: second.id))
    }

    @Test func builderRebuildsUserRowsWhenWorkspaceRootChanges() async throws {
        let workspaceRoot = "/Volumes/T7/文稿/Projects/agentGui"
        let message = Message.userFixture(text: "请查看 \(workspaceRoot)/agentGui/Views/MessageBubbleView.swift")

        let initial = ChatMessageListSnapshotBuilder.build(
            messages: [message],
            workspaceRoot: workspaceRoot,
            previous: [:]
        )

        let updated = ChatMessageListSnapshotBuilder.build(
            messages: [message],
            workspaceRoot: "",
            previous: initial.cache
        )

        #expect(initial.cachedEntry(for: message.id) !== updated.cachedEntry(for: message.id))
    }

    @Test func builderRebuildsOnlyAffectedRowWhenToolStateChanges() async throws {
        let session = Session(title: "Tools")
        let first = Message.userMessage(text: "keep", session: session)
        let second = Message.agentMessage(text: nil, session: session)
        let round = AgentRound(roundIndex: 0, message: second)
        round.text = "done"
        let tool = ToolCall(toolCallId: "exec-1", kind: .execute, message: second, agentRound: round)
        tool.title = "xcodebuild"
        tool.status = .inProgress
        round.toolCalls = [tool]
        second.agentRounds = [round]

        let initial = ChatMessageListSnapshotBuilder.build(
            messages: [first, second],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: [:]
        )

        tool.status = .success
        tool.endTime = Date()

        let updated = ChatMessageListSnapshotBuilder.build(
            messages: [first, second],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: initial.cache
        )

        #expect(initial.cachedEntry(for: first.id) === updated.cachedEntry(for: first.id))
        #expect(initial.cachedEntry(for: second.id) !== updated.cachedEntry(for: second.id))
    }

    @Test func builderRebuildsAgentRowWhenStatusChangesFromPendingToCompleted() async throws {
        let session = Session(title: "Projection Status")
        let message = Message.agentMessage(text: "最终结果", session: session)
        message.status = .pending

        let initial = ChatMessageListSnapshotBuilder.build(
            messages: [message],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: [:]
        )

        message.status = .completed

        let updated = ChatMessageListSnapshotBuilder.build(
            messages: [message],
            workspaceRoot: "/Volumes/T7/文稿/Projects/agentGui",
            previous: initial.cache
        )

        #expect(initial.cachedEntry(for: message.id) !== updated.cachedEntry(for: message.id))
    }
}