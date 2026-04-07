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

// MARK: - Tests (空壳，Task 3 后填入实际断言)

@Suite("MessageRewindContextMenuCoordinator")
struct MessageRewindContextMenuCoordinatorTests {

    @Test("PLACEHOLDER — Step 3 中替换")
    @MainActor
    func placeholder() async throws {
        #expect(true)
    }
}
