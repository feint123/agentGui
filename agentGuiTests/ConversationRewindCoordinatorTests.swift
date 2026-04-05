// agentGuiTests/ConversationRewindCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let session = Session()
    ctx.insert(session)
    return session
}

/// sequence 从 1 开始，direction 默认 .user
@MainActor
private func makeMessage(
    direction: MessageDirection = .user,
    sequence: Int,
    status: MessageStatus = .completed,
    in ctx: ModelContext,
    session: Session
) -> Message {
    let msg = Message(direction: direction, text: "content-\(sequence)", session: session)
    msg.sequence = sequence
    msg.status = status
    ctx.insert(msg)
    return msg
}

/// 在 message 上挂一个 AgentRound，再在 AgentRound 上挂一个 ToolCall
@MainActor
private func attachAgentRound(to message: Message, in ctx: ModelContext) -> (AgentRound, ToolCall) {
    let round = AgentRound(roundIndex: 0, message: message)
    ctx.insert(round)

    let tool = ToolCall(toolCallId: UUID().uuidString, kind: .read, agentRound: round)
    ctx.insert(tool)

    return (round, tool)
}

// MARK: - Test Suite

@MainActor
@Suite("ConversationRewindCoordinator Tests")
struct ConversationRewindCoordinatorTests {

    // MARK: - rewindTo: 基础截断

    @Test
    func rewindTo_deletesTargetMessageAndAllSubsequentMessages() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        try ctx.save()

        // 回滚到 m3（删 m3、m4，保留 m1、m2）
        let deletedCount = try await coordinator.rewindTo(message: m3)

        #expect(deletedCount == 2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        let remainingSeqs = remaining.map(\.sequence).sorted()
        #expect(remainingSeqs == [1, 2])
        #expect(remaining.contains(where: { $0.id == m1.id }))
        #expect(remaining.contains(where: { $0.id == m2.id }))
    }

    @Test
    func rewindTo_preservesMessagesBeforeTarget() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        try ctx.save()

        // 回滚到 sequence=2（只删 m2）
        _ = try await coordinator.rewindTo(message: m2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == m1.id)
    }

    @Test
    func rewindTo_returnsCorrectDeletedCount() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        _ = makeMessage(sequence: 5, in: ctx, session: session)
        try ctx.save()

        let count = try await coordinator.rewindTo(message: m3)
        #expect(count == 3) // m3, m4, m5
    }

    // MARK: - Cascade Delete

    @Test
    func rewindTo_cascadesDeleteToAgentRoundsAndToolCalls() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)

        // m2 上挂一个 AgentRound + 一个 ToolCall
        let (round, tool) = attachAgentRound(to: m2, in: ctx)
        try ctx.save()

        let roundID = round.id
        let toolID = tool.id

        _ = try await coordinator.rewindTo(message: m2)

        let rounds = try ctx.fetch(FetchDescriptor<AgentRound>())
        let tools = try ctx.fetch(FetchDescriptor<ToolCall>())
        #expect(!rounds.contains(where: { $0.id == roundID }), "AgentRound 应被 cascade 删除")
        #expect(!tools.contains(where: { $0.id == toolID }), "ToolCall 应被 cascade 删除")
    }

    @Test
    func rewindTo_doesNotDeleteUnrelatedSessionMessages() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session1 = makeSession(in: ctx)
        let session2 = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        _ = makeMessage(sequence: 1, in: ctx, session: session1)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session1)

        // session2 中有独立消息，不应被影响
        _ = makeMessage(sequence: 1, in: ctx, session: session2)
        _ = makeMessage(sequence: 2, in: ctx, session: session2)
        try ctx.save()

        _ = try await coordinator.rewindTo(message: m2)

        let descriptor = FetchDescriptor<Message>()
        let remaining = try ctx.fetch(descriptor)
        // session1 剩 1 条，session2 保留 2 条
        #expect(remaining.count == 3)
    }

    // MARK: - 边界情况

    @Test
    func rewindTo_singleMessage_deletesIt_returnsOne() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        let count = try await coordinator.rewindTo(message: m1)

        #expect(count == 1)
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.isEmpty)
    }

    @Test
    func rewindTo_messageNotAttachedToSession_throwsError() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        // 创建一个未关联到 session 的 message
        let orphan = Message(direction: .user, text: "orphan", session: nil)
        orphan.sequence = 1
        ctx.insert(orphan)
        try ctx.save()

        do {
            _ = try await coordinator.rewindTo(message: orphan)
            #expect(Bool(false), "应抛出 RewindError.messageNotAttachedToSession")
        } catch RewindError.messageNotAttachedToSession {
            // expected
        }
    }

    // MARK: - 通知

    @Test
    func rewindTo_postsNotification_withSessionID() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let coordinator = ConversationRewindCoordinator(modelContext: ctx)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        try ctx.save()

        let sessionID = session.sessionId

        var receivedSessionIDs: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidPruneConversation,
            object: nil,
            queue: .main
        ) { notification in
            if let id = notification.object as? String {
                receivedSessionIDs.append(id)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.rewindTo(message: m1)

        // 等一个 runloop tick 让通知分发
        try await Task.sleep(for: .milliseconds(50))
        #expect(receivedSessionIDs.contains(sessionID))
    }
}
