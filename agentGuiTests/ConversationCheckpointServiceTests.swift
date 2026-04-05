// agentGuiTests/ConversationCheckpointServiceTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Helpers

private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([ConversationCheckpoint.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

@Suite("ConversationCheckpointService Tests")
struct ConversationCheckpointServiceTests {

    // MARK: - makeSnapshot: 有条目

    @Test
    func makeSnapshot_withEntries_persistsCheckpointToSwiftData() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let msgID = UUID()
        let sessionID = "session-test-1"
        let acc = ActiveCheckpointAccumulator(messageID: msgID, workspaceRoot: tmp.path)

        // 模拟 FileCheckpointHook 记录了一个条目
        await acc.record(
            relativePath: "src/main.swift",
            entry: FileBackupEntry(
                backupKey: "abc123",
                version: 1,
                backupTime: Date(),
                originalRelativePath: "src/main.swift"
            )
        )

        try await service.makeSnapshot(
            accumulator: acc,
            sessionID: sessionID,
            modelContext: ctx
        )

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)

        #expect(checkpoints.count == 1)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == msgID)
        #expect(cp.sessionID == sessionID)
        #expect(cp.workspaceRoot == tmp.path)
        #expect(cp.hasFileChanges == true)
        #expect(cp.snapshotSequence == 0)

        let backups = try cp.decodedTrackedFileBackups()
        #expect(backups["src/main.swift"]?.backupKey == "abc123")
    }

    // MARK: - makeSnapshot: 无条目

    @Test
    func makeSnapshot_emptyEntries_hasFileChanges_isFalse() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        // 不记录任何条目

        try await service.makeSnapshot(
            accumulator: acc,
            sessionID: "session-empty",
            modelContext: ctx
        )

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == "session-empty" }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.hasFileChanges == false)
        #expect(cp.snapshotSequence == 0)
    }

    // MARK: - snapshotSequence 单调递增

    @Test
    func makeSnapshot_multipleSnapshots_sequenceIsMonotonic() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)
        let sessionID = "session-seq"

        for i in 0..<3 {
            let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
            await acc.record(
                relativePath: "file\(i).swift",
                entry: FileBackupEntry(backupKey: "key\(i)", version: 1, backupTime: Date(), originalRelativePath: "file\(i).swift")
            )
            try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)
        }

        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.snapshotSequence)]
        )
        let checkpoints = try ctx.fetch(descriptor)
        #expect(checkpoints.count == 3)
        #expect(checkpoints.map(\.snapshotSequence) == [0, 1, 2])
    }

    // MARK: - fetchCheckpoints

    @Test
    func fetchCheckpoints_returnsLatestFirst() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)
        let sessionID = "session-fetch"

        for _ in 0..<5 {
            let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
            try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)
        }

        let checkpoints = try await service.fetchCheckpoints(sessionID: sessionID, limit: 3, modelContext: ctx)
        #expect(checkpoints.count == 3)
        // 最新的 snapshotSequence 在前
        #expect(checkpoints[0].snapshotSequence > checkpoints[1].snapshotSequence)
        #expect(checkpoints[1].snapshotSequence > checkpoints[2].snapshotSequence)
    }

    // MARK: - prepareAccumulator messageID 传播

    @Test
    func prepareAccumulator_returnsAccumulatorWithCorrectMessageID() async {
        let tmp = try! makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let expectedID = UUID()
        let acc = await service.prepareAccumulator(
            messageID: expectedID,
            sessionID: "s",
            workspaceRoot: "/ws"
        )
        let actualID = await acc.messageID
        #expect(actualID == expectedID)
    }

    // MARK: - prepare + makeSnapshot 完整生命周期

    @Test
    func fullLifecycle_prepareAndMakeSnapshot_matchesMessageID() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let userMsgID = UUID()
        let sessionID = "session-full"

        // Pre-loop: 创建 accumulator
        let acc = await service.prepareAccumulator(
            messageID: userMsgID,
            sessionID: sessionID,
            workspaceRoot: tmp.path
        )

        // 模拟 FileCheckpointHook 在 loop 中写入
        await acc.record(
            relativePath: "app.swift",
            entry: FileBackupEntry(backupKey: "deadbeef", version: 1, backupTime: Date(), originalRelativePath: "app.swift")
        )

        // Post-loop: 创建快照
        try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)

        // 验证 checkpoint 已持久化，且 messageID 与 userMsgID 一致
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == userMsgID)
        #expect(cp.hasFileChanges == true)
    }

    // MARK: - 冒烟: Hook → Accumulator → Checkpoint 完整链路

    @Test
    func smokeTest_hookFillsAccumulator_snapshotPersistedWithBackupKey() async throws {
        let container = try makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tmp = try makeTempDir()
        let store = FileBackupStore(baseURL: tmp.appendingPathComponent("backups"))
        let service = ConversationCheckpointService(fileBackupStore: store)

        let sessionID = "smoke-session"
        let userMsgID = UUID()

        // 1. 在 workspaceRoot 创建待备份文件
        let wsRoot = tmp.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        let targetFile = wsRoot.appendingPathComponent("Foo.swift")
        try "original content".write(to: targetFile, atomically: true, encoding: .utf8)

        // 2. Pre-loop: 创建 accumulator
        let acc = await service.prepareAccumulator(
            messageID: userMsgID,
            sessionID: sessionID,
            workspaceRoot: wsRoot.path
        )

        // 3. 模拟 FileCheckpointHook.preExecute：
        //    直接用 FileBackupStore 备份文件并记录到 accumulator
        let entry = try await store.createBackup(
            filePath: targetFile.path,
            sessionID: sessionID,
            version: 1
        )
        let backupEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: entry.version,
            backupTime: entry.backupTime,
            originalRelativePath: "Foo.swift"
        )
        await acc.record(relativePath: "Foo.swift", entry: backupEntry)

        // 4. Post-loop: makeSnapshot
        try await service.makeSnapshot(accumulator: acc, sessionID: sessionID, modelContext: ctx)

        // 5. 验证 SwiftData 中有 checkpoint，且 backupKey 非 nil
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let checkpoints = try ctx.fetch(descriptor)
        let cp = try #require(checkpoints.first)
        #expect(cp.messageID == userMsgID)
        #expect(cp.hasFileChanges == true)

        let backups = try cp.decodedTrackedFileBackups()
        let persistedEntry = try #require(backups["Foo.swift"])
        #expect(persistedEntry.backupKey != nil)

        // 6. 验证磁盘上备份文件存在
        let key = try #require(persistedEntry.backupKey)
        let backupFile = tmp
            .appendingPathComponent("backups/\(sessionID)/\(String(key.prefix(2)))/\(key).bak")
        #expect(FileManager.default.fileExists(atPath: backupFile.path))
        let backedContent = try String(contentsOf: backupFile, encoding: .utf8)
        #expect(backedContent == "original content")
    }
}
