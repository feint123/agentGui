import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationCheckpointModelTests {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Insert / Fetch / Delete

    @Test
    func insertsAndFetchesCheckpoint() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let messageID = UUID()
        let checkpoint = try ConversationCheckpoint(
            sessionID: "session-1",
            messageID: messageID,
            snapshotSequence: 0,
            workspaceRoot: "/tmp/workspace"
        )
        context.insert(checkpoint)
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-1" }
        let results = try context.fetch(descriptor)

        #expect(results.count == 1)
        #expect(results.first?.messageID == messageID)
        #expect(results.first?.workspaceRoot == "/tmp/workspace")
        #expect(results.first?.snapshotSequence == 0)
        #expect(results.first?.hasFileChanges == false)
    }

    @Test
    func deletesCheckpointWithoutCascadingToMessages() throws {
        // ConversationCheckpoint 与 Message 无 @Relationship，
        // 删除检查点不应影响 Message；此测试验证独立删除可行。
        let container = try makeContainer()
        let context = ModelContext(container)

        let checkpoint = try ConversationCheckpoint(
            sessionID: "session-del",
            messageID: UUID(),
            snapshotSequence: 1,
            workspaceRoot: "/tmp/ws"
        )
        context.insert(checkpoint)
        try context.save()

        context.delete(checkpoint)
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-del" }
        let results = try context.fetch(descriptor)
        #expect(results.isEmpty)
    }

    @Test
    func fetchesMultipleCheckpointsSortedBySequence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        for i in 0..<5 {
            let cp = try ConversationCheckpoint(
                sessionID: "session-multi",
                messageID: UUID(),
                snapshotSequence: i,
                workspaceRoot: "/tmp/ws"
            )
            context.insert(cp)
        }
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-multi" }
        descriptor.sortBy = [SortDescriptor(\ConversationCheckpoint.snapshotSequence)]
        let results = try context.fetch(descriptor)

        #expect(results.count == 5)
        #expect(results.map(\.snapshotSequence) == [0, 1, 2, 3, 4])
    }

    // MARK: - JSON 往返序列化

    @Test
    func emptyBackupsSerializesToEmptyJSON() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )
        let decoded = try checkpoint.decodedTrackedFileBackups()
        #expect(decoded.isEmpty)
        #expect(checkpoint.hasFileChanges == false)
    }

    @Test
    func backupEntryRoundTripsCorrectly() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        let backupTime = Date(timeIntervalSince1970: 1_000_000)
        let entry = FileBackupEntry(
            backupKey: "abc123def456",
            version: 1,
            backupTime: backupTime,
            originalRelativePath: "src/main.swift"
        )
        try checkpoint.setTrackedFileBackups(["src/main.swift": entry])

        let decoded = try checkpoint.decodedTrackedFileBackups()

        #expect(decoded.count == 1)
        let roundTripped = try #require(decoded["src/main.swift"])
        #expect(roundTripped.backupKey == "abc123def456")
        #expect(roundTripped.version == 1)
        #expect(roundTripped.originalRelativePath == "src/main.swift")
        // Date 精度：允许 0.001 秒误差（JSON 浮点数精度）
        #expect(abs(roundTripped.backupTime.timeIntervalSince(backupTime)) < 0.001)
    }

    @Test
    func nilBackupKeyRoundTripsAsNil() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        // backupKey = nil 表示该文件在快照时刻不存在
        let entry = FileBackupEntry(
            backupKey: nil,
            version: 0,
            backupTime: Date(),
            originalRelativePath: "new-file.txt"
        )
        try checkpoint.setTrackedFileBackups(["new-file.txt": entry])

        let decoded = try checkpoint.decodedTrackedFileBackups()
        let roundTripped = try #require(decoded["new-file.txt"])
        #expect(roundTripped.backupKey == nil)
        #expect(roundTripped.fileExistedAtSnapshot == false)
    }

    @Test
    func multipleEntriesRoundTripCorrectly() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        let entries: [String: FileBackupEntry] = [
            "a.swift": FileBackupEntry(
                backupKey: "hash-a",
                version: 1,
                backupTime: Date(timeIntervalSince1970: 1_000),
                originalRelativePath: "a.swift"
            ),
            "b.swift": FileBackupEntry(
                backupKey: nil,
                version: 0,
                backupTime: Date(timeIntervalSince1970: 2_000),
                originalRelativePath: "b.swift"
            ),
        ]
        try checkpoint.setTrackedFileBackups(entries)

        #expect(checkpoint.hasFileChanges == true)

        let decoded = try checkpoint.decodedTrackedFileBackups()
        #expect(decoded.count == 2)
        #expect(decoded["a.swift"]?.backupKey == "hash-a")
        #expect(decoded["b.swift"]?.backupKey == nil)
    }

    // MARK: - hasFileChanges 标志

    @Test
    func hasFileChangesIsFalseWhenBackupsEmpty() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        #expect(checkpoint.hasFileChanges == false)
    }

    @Test
    func hasFileChangesIsTrueWhenBackupsProvided() throws {
        let entry = FileBackupEntry(
            backupKey: "somehash",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "file.swift"
        )
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: ["file.swift": entry],
            hasFileChanges: true
        )
        #expect(checkpoint.hasFileChanges == true)
    }

    @Test
    func setTrackedFileBackupsUpdatesHasFileChangesFlag() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )
        #expect(checkpoint.hasFileChanges == false)

        let entry = FileBackupEntry(
            backupKey: "h",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "x.swift"
        )
        try checkpoint.setTrackedFileBackups(["x.swift": entry])
        #expect(checkpoint.hasFileChanges == true)

        // 清空后 flag 应重置为 false
        try checkpoint.setTrackedFileBackups([:])
        #expect(checkpoint.hasFileChanges == false)
    }

    // MARK: - FileBackupEntry helpers

    @Test
    func fileExistedAtSnapshotReturnsTrueWhenBackupKeyNotNil() {
        let entry = FileBackupEntry(
            backupKey: "abc",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "file.swift"
        )
        #expect(entry.fileExistedAtSnapshot == true)
    }

    @Test
    func fileExistedAtSnapshotReturnsFalseWhenBackupKeyIsNil() {
        let entry = FileBackupEntry(
            backupKey: nil,
            version: 0,
            backupTime: Date(),
            originalRelativePath: "new.swift"
        )
        #expect(entry.fileExistedAtSnapshot == false)
    }
}
