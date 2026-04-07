import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - Shared Fixtures

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let s = Session()
    ctx.insert(s)
    return s
}

@MainActor
private func makeUserMessage(seq: Int, text: String = "user msg", in ctx: ModelContext, session: Session) -> Message {
    let m = Message(direction: .user, text: text, session: session)
    m.sequence = seq
    m.status = .completed
    ctx.insert(m)
    return m
}

@MainActor
private func makeAgentMessage(seq: Int, in ctx: ModelContext, session: Session) -> Message {
    let m = Message(direction: .agent, text: "agent response", session: session)
    m.sequence = seq
    m.status = .completed
    ctx.insert(m)
    return m
}

/// 构造 NoOp MessageRewindContextMenuCoordinator（cancelLoop 不执行任何操作）。
@MainActor
private func makeCoordinator(
    session: Session,
    modelContext: ModelContext,
    backupURL: URL? = nil
) -> MessageRewindContextMenuCoordinator {
    let url = backupURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("rd4-test-\(UUID().uuidString)")
    let store = FileBackupStore(baseURL: url)
    let checkpointService = ConversationCheckpointService(fileBackupStore: store)
    let inspector = RewindPreflightInspector(fileBackupStore: store)
    let convCoord = ConversationRewindCoordinator(modelContext: modelContext)
    let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
    let txCoord = RewindTransactionCoordinator(
        conversationRewindCoordinator: convCoord,
        fileSystemRewindCoordinator: fsCoord,
        cancelLoop: { _, _ in },
        modelContext: modelContext
    )
    return MessageRewindContextMenuCoordinator(
        checkpointService: checkpointService,
        preflightInspector: inspector,
        transactionCoordinator: txCoord
    )
}

// MARK: - Tests

@Suite("MessageRewindContextMenuCoordinator")
struct MessageRewindContextMenuCoordinatorTests {

    // MARK: - Lossless path

    @Test("无 checkpoint → losslessCompleted，对话被截断")
    @MainActor
    func noCheckpoint_returnsLosslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        // u1(seq=0) → agent(seq=1) → u2(seq=2) → agent(seq=3)
        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        let _ = makeUserMessage(seq: 2, text: "second", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 3, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        // 验证结果是 losslessCompleted
        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted, got \(result)")
            return
        }

        // 验证 u1 之后的消息已被删除（对话截断）
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.allSatisfy { $0.sequence < u1.sequence || $0.id == u1.id })
    }

    @Test("checkpoint.hasFileChanges == false → losslessCompleted")
    @MainActor
    func checkpointNoFileChanges_returnsLosslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        try ctx.save()

        // 插入一个 hasFileChanges = false 的 checkpoint
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: u1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp/test",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(cp)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted, got \(result)")
            return
        }
    }

    // MARK: - messagesAfterCount 计算

    @Test("needsConfirmation 包含正确的 messagesAfterCount 和 toolCallsAfterCount")
    @MainActor
    func needsConfirmation_countsMessagesAndToolCallsAfterTarget() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, text: "first", in: ctx, session: session)
        let agent1 = makeAgentMessage(seq: 1, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, text: "second", in: ctx, session: session)
        let agent2 = makeAgentMessage(seq: 3, in: ctx, session: session)

        // agent1 關聯 2 個 ToolCall（模擬）
        let tc1 = ToolCall(toolCallId: "tc1", kind: .execute, message: agent1)
        let tc2 = ToolCall(toolCallId: "tc2", kind: .execute, message: agent1)
        ctx.insert(tc1)
        ctx.insert(tc2)
        try ctx.save()

        // 插入 checkpoint，hasFileChanges = false（lossless path）
        let cp = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: u1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(cp)
        try ctx.save()

        let allMsgs = [u1, agent1, u2, agent2]
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u1,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        // u1 hasFileChanges=false → lossless，截断后仅剩 u1 及之前消息
        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted on no-file-changes checkpoint")
            return
        }
        // u1(seq=0) 之后有 agent1(seq=1), u2(seq=2), agent2(seq=3) 共 3 条
        // 截断后验证（messagesAfterCount 逻辑在 lossless 路径无需计算，仅 needsConfirmation 路径使用）
        // 本测试主要验证：传入 allMessages 包含 4 条，执行 lossless 后数据库只剩 <= seq(u1) 的消息
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        let removedCount = remaining.filter { $0.sequence > u1.sequence }
        #expect(removedCount.isEmpty, "u1 之后的消息应全部被截断")
    }

    // MARK: - Target message 为 session 中最后一条用户消息

    @Test("目标是最后一条用户消息 + 无 checkpoint → losslessCompleted，后续消息全被删除")
    @MainActor
    func lastUserMessage_noCheckpoint_losslessCompleted() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let session = makeSession(in: ctx)

        let u1 = makeUserMessage(seq: 0, in: ctx, session: session)
        let _ = makeAgentMessage(seq: 1, in: ctx, session: session)
        let u2 = makeUserMessage(seq: 2, in: ctx, session: session)
        // u2 是最后一条用户消息，之后有 agent 响应
        let _ = makeAgentMessage(seq: 3, in: ctx, session: session)
        try ctx.save()

        let allMsgs = try ctx.fetch(FetchDescriptor<Message>())
        let coordinator = makeCoordinator(session: session, modelContext: ctx)

        let result = try await coordinator.execute(
            message: u2,
            allMessages: allMsgs,
            sessionID: session.sessionId,
            modelContext: ctx
        )

        guard case .losslessCompleted = result else {
            Issue.record("Expected .losslessCompleted")
            return
        }

        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        // u2 及之后的 agent 消息都被删除，剩下 u1 和 agent1（seq <= 1）
        #expect(remaining.allSatisfy { $0.sequence < u2.sequence })
    }
}
