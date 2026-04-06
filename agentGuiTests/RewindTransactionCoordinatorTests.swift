// agentGuiTests/RewindTransactionCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Shared Helpers

/// 用于记录 cancelLoop 调用的引用类型（避免 @escaping 闭包捕获 inout 问题）
@MainActor
private final class CancelLog {
    var calls: [String] = []
}

/// 构造内存模型容器
@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 创建测试用 Session
@MainActor
private func makeSession(in ctx: ModelContext) -> Session {
    let s = Session()
    ctx.insert(s)
    return s
}

/// 创建有 sequence 的 Message
@MainActor
private func makeMessage(
    direction: MessageDirection = .user,
    sequence: Int,
    status: MessageStatus = .completed,
    text: String? = nil,
    in ctx: ModelContext,
    session: Session
) -> Message {
    let msg = Message(direction: direction, text: text ?? "msg\(sequence)", session: session)
    msg.sequence = sequence
    msg.status = status
    ctx.insert(msg)
    return msg
}

/// 构造不抛出的 RewindTransactionCoordinator（cancelLoop 记录调用）
@MainActor
private func makeCoordinator(
    ctx: ModelContext,
    cancelLog: CancelLog,
    backupBaseURL: URL? = nil
) -> RewindTransactionCoordinator {
    let convCoord = ConversationRewindCoordinator(modelContext: ctx)
    let store = FileBackupStore(baseURL: backupBaseURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("rc4-test-\(UUID().uuidString)"))
    let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
    return RewindTransactionCoordinator(
        conversationRewindCoordinator: convCoord,
        fileSystemRewindCoordinator: fsCoord,
        cancelLoop: { [cancelLog] sessionID, _ in
            cancelLog.calls.append(sessionID)
        },
        modelContext: ctx
    )
}

// MARK: - Test Suite: conversationOnly

@MainActor
@Suite("RewindTransactionCoordinator — conversationOnly")
struct RewindTransactionCoordinatorConversationOnlyTests {

    @Test
    func conversationOnly_truncatesMessagesAtAndAfterTarget() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        let m2 = makeMessage(sequence: 2, in: ctx, session: session)
        let m3 = makeMessage(sequence: 3, in: ctx, session: session)
        _ = makeMessage(sequence: 4, in: ctx, session: session)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m3,
            checkpoint: nil,
            option: .conversationOnly
        )

        // 对话被截断
        #expect(result.messagesDeleted == 2)   // m3, m4

        // 文件操作为 0
        #expect(result.filesRestored == 0)
        #expect(result.filesSkipped == 0)
        #expect(result.filesFailed == 0)

        // m1, m2 保留
        let remaining = try ctx.fetch(FetchDescriptor<Message>())
        #expect(remaining.map(\.sequence).sorted() == [1, 2])
        _ = m1; _ = m2  // suppress unused warning
    }

    @Test
    func conversationOnly_cancelsRunningLoop() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly
        )

        // cancelLoop 应被调用一次，传入 session.sessionId
        #expect(cancelLog.calls.count == 1)
        #expect(cancelLog.calls[0] == session.sessionId)
    }

    @Test
    func conversationOnly_messsageNotAttachedToSession_throws() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let orphan = Message(direction: .user, text: "orphan", session: nil)
        ctx.insert(orphan)
        try ctx.save()

        await #expect(throws: RewindTransactionError.messageNotAttachedToSession) {
            _ = try await coordinator.execute(
                targetMessage: orphan,
                checkpoint: nil,
                option: .conversationOnly
            )
        }
    }

    @Test
    func conversationOnly_withCheckpointNil_succeeds() async throws {
        // checkpoint=nil 对于 conversationOnly 是合法的
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly
        )
        #expect(result.messagesDeleted == 1)
    }
}

// MARK: - Test Suite: filesOnly

@MainActor
@Suite("RewindTransactionCoordinator — filesOnly")
struct RewindTransactionCoordinatorFilesOnlyTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc4-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test
    func filesOnly_restoresFilesButDoesNotTruncateConversation() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)

        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let convCoord = ConversationRewindCoordinator(modelContext: ctx)
        let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
        let cancelLog = CancelLog()

        let coordinator = RewindTransactionCoordinator(
            conversationRewindCoordinator: convCoord,
            fileSystemRewindCoordinator: fsCoord,
            cancelLoop: { [cancelLog] sessionID, _ in cancelLog.calls.append(sessionID) },
            modelContext: ctx
        )

        // 创建对话（3 条消息）
        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        _ = makeMessage(sequence: 3, in: ctx, session: session)
        try ctx.save()

        // 创建文件备份
        let filePath = workspaceRoot + "/f1.txt"
        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: session.sessionId, version: 0)

        // 修改文件（模拟 agent 改了它）
        try "modified".write(toFile: filePath, atomically: true, encoding: .utf8)

        // 创建 checkpoint
        let checkpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: ["f1.txt": entry],
            hasFileChanges: true
        )
        ctx.insert(checkpoint)
        try ctx.save()

        // 执行 filesOnly
        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: checkpoint,
            option: .filesOnly
        )

        // 文件恢复了
        #expect(result.filesRestored == 1)
        let restoredContent = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(restoredContent == "original")

        // 对话消息全部保留
        #expect(result.messagesDeleted == 0)
        let allMessages = try ctx.fetch(FetchDescriptor<Message>())
        #expect(allMessages.count == 3)
    }

    @Test
    func filesOnly_withNilCheckpoint_throwsCheckpointRequired() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        await #expect(throws: RewindTransactionError.checkpointRequiredForFileRestore) {
            _ = try await coordinator.execute(
                targetMessage: m1,
                checkpoint: nil,
                option: .filesOnly
            )
        }
    }

    @Test
    func filesOnly_cancelsRunningLoop() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        // 不需要真实备份文件，只测 cancelLoop 被调用
        // 但 filesOnly 需要 checkpoint，所以传一个空 checkpoint
        let emptyCheckpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        ctx.insert(emptyCheckpoint)
        try ctx.save()

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: emptyCheckpoint,
            option: .filesOnly
        )

        // cancelLoop 应被调用
        #expect(cancelLog.calls.count == 1)
    }
}

// MARK: - Test Suite: conversationAndFiles

@MainActor
@Suite("RewindTransactionCoordinator — conversationAndFiles")
struct RewindTransactionCoordinatorConversationAndFilesTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc4-caf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test
    func conversationAndFiles_truncatesConversationAndRestoresFiles() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let cancelLog = CancelLog()
        let coordinator = RewindTransactionCoordinator(
            conversationRewindCoordinator: ConversationRewindCoordinator(modelContext: ctx),
            fileSystemRewindCoordinator: FileSystemRewindCoordinator(fileBackupStore: store),
            cancelLoop: { [cancelLog] s, _ in cancelLog.calls.append(s) },
            modelContext: ctx
        )

        // 对话：m1 是回滚目标，m2/m3 将被删除
        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        _ = makeMessage(sequence: 2, in: ctx, session: session)
        _ = makeMessage(sequence: 3, in: ctx, session: session)
        try ctx.save()

        // 文件
        let filePath = workspaceRoot + "/code.swift"
        try "let x = 1".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: session.sessionId, version: 0)
        try "let x = 999".write(toFile: filePath, atomically: true, encoding: .utf8)

        let checkpoint = try ConversationCheckpoint(
            sessionID: session.sessionId,
            messageID: m1.id,
            snapshotSequence: 0,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: ["code.swift": entry],
            hasFileChanges: true
        )
        ctx.insert(checkpoint)
        try ctx.save()

        let result = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: checkpoint,
            option: .conversationAndFiles
        )

        // 对话截断（m1, m2, m3 全删）
        #expect(result.messagesDeleted == 3)

        // 文件恢复
        #expect(result.filesRestored == 1)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content == "let x = 1")

        // loop 被取消
        #expect(cancelLog.calls.count == 1)
    }

    @Test
    func conversationAndFiles_withNilCheckpoint_throwsCheckpointRequired() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, in: ctx, session: session)
        try ctx.save()

        await #expect(throws: RewindTransactionError.checkpointRequiredForFileRestore) {
            _ = try await coordinator.execute(
                targetMessage: m1,
                checkpoint: nil,
                option: .conversationAndFiles
            )
        }
    }
}

// MARK: - Test Suite: rewindDidComplete notification

@MainActor
@Suite("RewindTransactionCoordinator — rewindDidComplete notification")
struct RewindTransactionCoordinatorNotificationTests {

    @Test
    func execute_postsRewindDidCompleteNotification() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, text: "hello world", in: ctx, session: session)
        try ctx.save()

        var receivedNotification: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidComplete,
            object: nil,
            queue: .main
        ) { notification in
            receivedNotification = notification
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly,
            repopulateInput: true
        )

        #expect(receivedNotification != nil)
        #expect(receivedNotification?.userInfo?["sessionID"] as? String == session.sessionId)
        #expect(receivedNotification?.userInfo?["repopulateText"] as? String == "hello world")
        #expect(receivedNotification?.userInfo?["option"] as? String == "conversationOnly")
    }

    @Test
    func execute_repopulateInputFalse_notificationHasNilText() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let session = makeSession(in: ctx)
        let cancelLog = CancelLog()
        let coordinator = makeCoordinator(ctx: ctx, cancelLog: cancelLog)

        let m1 = makeMessage(sequence: 1, text: "some text", in: ctx, session: session)
        try ctx.save()

        var receivedNotification: Notification?
        let observer = NotificationCenter.default.addObserver(
            forName: .rewindDidComplete,
            object: nil,
            queue: .main
        ) { notification in
            receivedNotification = notification
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await coordinator.execute(
            targetMessage: m1,
            checkpoint: nil,
            option: .conversationOnly,
            repopulateInput: false
        )

        // repopulateInput=false → repopulateText 不出现或为 nil
        let text = receivedNotification?.userInfo?["repopulateText"]
        // userInfo["repopulateText"] 存入了 nil as Any，Swift 取出时为 Optional<Any>.none
        let isNilText = text == nil || (text as? String) == nil
        #expect(isNilText)
    }
}
