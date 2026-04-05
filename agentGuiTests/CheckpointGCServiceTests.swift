import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct CheckpointGCServiceTests {

    // MARK: - Helpers

    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([ConversationCheckpoint.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func insertCheckpoint(
        sessionID: String,
        sequence: Int,
        context: ModelContext
    ) throws -> ConversationCheckpoint {
        let cp = try ConversationCheckpoint(
            sessionID: sessionID,
            messageID: UUID(),
            snapshotSequence: sequence,
            workspaceRoot: "/tmp/ws",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        context.insert(cp)
        return cp
    }

    // MARK: - evictOldCheckpoints

    @Test
    func eviction_keepsLatestNCheckpoints_deletesOlderOnes() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s1", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s1", modelContext: context, maxCheckpoints: 5)

        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s1" },
                sortBy: [SortDescriptor(\.snapshotSequence)]
            )
        )
        // 保留最新 5 条（sequence 5..9），删除旧 5 条（sequence 0..4）
        #expect(remaining.count == 5)
        #expect(remaining.first?.snapshotSequence == 5)
        #expect(remaining.last?.snapshotSequence == 9)
    }

    @Test
    func eviction_doesNothing_whenBelowLimit() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<3 {
            _ = try insertCheckpoint(sessionID: "s2", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s2", modelContext: context, maxCheckpoints: 50)

        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s2" }
            )
        )
        #expect(remaining.count == 3)
    }

    @Test
    func eviction_isolatedPerSession_doesNotTouchOtherSessions() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s3", sequence: seq, context: context)
        }
        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s4", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s3", modelContext: context, maxCheckpoints: 3)

        let s3Remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s3" }
            )
        )
        let s4Remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s4" }
            )
        )
        #expect(s3Remaining.count == 3)
        #expect(s4Remaining.count == 10)  // s4 未受影响
    }

    // MARK: - pruneOrphanBackupFiles

    @Test
    func pruneOrphans_deletesUnreferencedBackupFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 创建备份文件：一个有引用，一个孤立
        let referencedKey = "aabbcc.v1"
        let orphanKey     = "deadbeef.v1"

        func createBakFile(key: String) throws -> URL {
            let shard = String(key.prefix(2))
            let dir = tmpDir
                .appendingPathComponent("s1")
                .appendingPathComponent(shard)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(key).bak")
            try "content".write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let referencedURL = try createBakFile(key: referencedKey)
        let orphanURL     = try createBakFile(key: orphanKey)

        // 只在 SwiftData 中引用 referencedKey
        let container = try makeTestContainer()
        let context = container.mainContext
        let cp = try ConversationCheckpoint(
            sessionID: "s1",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [
                "file.swift": FileBackupEntry(
                    backupKey: referencedKey,
                    version: 1,
                    backupTime: Date(),
                    originalRelativePath: "file.swift"
                )
            ],
            hasFileChanges: true
        )
        context.insert(cp)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.pruneOrphanBackupFiles(sessionID: "s1", modelContext: context)

        // 有引用的文件不删
        #expect(FileManager.default.fileExists(atPath: referencedURL.path))
        // 孤立文件被删
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test
    func pruneOrphans_doesNothing_whenAllFilesReferenced() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let key = "112233.v1"
        let shard = String(key.prefix(2))
        let dir = tmpDir.appendingPathComponent("s5").appendingPathComponent(shard)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bakURL = dir.appendingPathComponent("\(key).bak")
        try "x".write(to: bakURL, atomically: true, encoding: .utf8)

        let container = try makeTestContainer()
        let context = container.mainContext
        let cp = try ConversationCheckpoint(
            sessionID: "s5",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [
                "a.swift": FileBackupEntry(
                    backupKey: key, version: 1, backupTime: Date(), originalRelativePath: "a.swift"
                )
            ],
            hasFileChanges: true
        )
        context.insert(cp)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.pruneOrphanBackupFiles(sessionID: "s5", modelContext: context)

        #expect(FileManager.default.fileExists(atPath: bakURL.path))
    }

    // MARK: - purgeSession

    @Test
    func purgeSession_deletesAllCheckpointsAndBackupDirForSession() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 创建 session 备份目录和文件
        let sessionDir = tmpDir.appendingPathComponent("sess-purge", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let bakFile = sessionDir.appendingPathComponent("dummy.bak")
        try "data".write(to: bakFile, atomically: true, encoding: .utf8)

        // 写入 SwiftData
        let container = try makeTestContainer()
        let context = container.mainContext
        for seq in 0..<5 {
            _ = try insertCheckpoint(sessionID: "sess-purge", sequence: seq, context: context)
        }
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.purgeSession(sessionID: "sess-purge", modelContext: context)

        // SwiftData 中的检查点全部删除
        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "sess-purge" }
            )
        )
        #expect(remaining.isEmpty)

        // 磁盘上的 session 目录被删除
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }

    @Test
    func purgeSession_doesNotTouchOtherSessions() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // session A 和 B 各有一个备份文件
        for sid in ["sess-a", "sess-b"] {
            let dir = tmpDir.appendingPathComponent(sid, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("x.bak"), atomically: true, encoding: .utf8)
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        _ = try insertCheckpoint(sessionID: "sess-a", sequence: 0, context: context)
        _ = try insertCheckpoint(sessionID: "sess-b", sequence: 0, context: context)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.purgeSession(sessionID: "sess-a", modelContext: context)

        // sess-a 删除，sess-b 保留
        #expect(!FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("sess-a").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("sess-b").path
        ))
        let bRemaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "sess-b" }
            )
        )
        #expect(bRemaining.count == 1)
    }

    // MARK: - SessionDeletionCoordinator 集成

    @Test
    func sessionDeletion_triggersCheckpointPurge() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 建立带 sessionID 的 Session 模型
        let schema = Schema([
            ConversationCheckpoint.self,
            Session.self,
            Message.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = container.mainContext

        let session = Session()
        session.workingDirectory = "/tmp"
        let sid = session.sessionId
        context.insert(session)

        // 插入检查点
        let cp = try ConversationCheckpoint(
            sessionID: sid,
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        context.insert(cp)

        // 建立磁盘备份目录
        let sessionDir = tmpDir.appendingPathComponent(sid, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "bak".write(to: sessionDir.appendingPathComponent("x.bak"), atomically: true, encoding: .utf8)

        try context.save()

        // 执行删除（通过注入 gc）
        let gc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        let coordinator = SessionDeletionCoordinator(checkpointGCService: gc)
        try await coordinator.delete(session, modelContext: context)

        // 检查点应被删除
        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sid }
            )
        )
        #expect(remaining.isEmpty)

        // 备份目录应被删除
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }
}
