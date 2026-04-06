// agentGuiTests/RewindPreflightInspectorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Test Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 在内存 ModelContext 中插入一个 ConversationCheckpoint
@MainActor
private func makeCheckpoint(
    sessionID: String,
    workspaceRoot: String,
    entries: [String: FileBackupEntry],
    in ctx: ModelContext
) throws -> ConversationCheckpoint {
    let cp = try ConversationCheckpoint(
        sessionID: sessionID,
        messageID: UUID(),
        snapshotSequence: 0,
        workspaceRoot: workspaceRoot,
        trackedFileBackups: entries,
        hasFileChanges: !entries.isEmpty
    )
    ctx.insert(cp)
    return cp
}

// MARK: - Suite

@MainActor
@Suite("RewindPreflightInspector Tests")
struct RewindPreflightInspectorTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - hasAnyFileChanges

    /// 无追踪文件的空检查点 → hasAnyFileChanges = false
    @Test
    func hasAnyFileChanges_emptyCheckpoint_returnsFalse() async throws {
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let inspector = RewindPreflightInspector(fileBackupStore: store)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: "s1",
            workspaceRoot: workspaceRoot,
            entries: [:],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == false)
    }

    /// 文件内容与备份相同 → hasAnyFileChanges = false
    @Test
    func hasAnyFileChanges_fileUnchanged_returnsFalse() async throws {
        let sessionID = "s-unchanged-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // 创建文件并备份
        let filePath = workspaceRoot + "/foo.txt"
        try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["foo.txt": entry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == false)
    }

    /// 文件内容被修改 → hasAnyFileChanges = true
    @Test
    func hasAnyFileChanges_fileModified_returnsTrue() async throws {
        let sessionID = "s-modified-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/bar.txt"
        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 模拟 agent 修改文件
        try "modified by agent".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["bar.txt": entry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }

    /// backupKey == nil，文件现在存在 → hasAnyFileChanges = true（快照时文件不存在，现在存在）
    @Test
    func hasAnyFileChanges_nilBackupFileNowExists_returnsTrue() async throws {
        let sessionID = "s-nilback-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // nil backupKey = 快照时文件不存在
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: "new.txt"
        )

        // 但现在文件存在（由 agent 创建）
        let filePath = workspaceRoot + "/new.txt"
        try "created by agent".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["new.txt": nilEntry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }

    /// 早退验证：多个文件中第一个有变化，不继续检查后续文件（行为验证：仍返回 true，非性能测试）
    @Test
    func hasAnyFileChanges_earlyExitOnFirstChanged() async throws {
        let sessionID = "s-earlyexit-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // 两个文件，第一个已修改，第二个未修改
        let file1 = workspaceRoot + "/a.txt"
        let file2 = workspaceRoot + "/b.txt"
        try "original-a".write(toFile: file1, atomically: true, encoding: .utf8)
        try "original-b".write(toFile: file2, atomically: true, encoding: .utf8)
        let entry1 = try await store.createBackup(filePath: file1, sessionID: sessionID, version: 1)
        let entry2 = try await store.createBackup(filePath: file2, sessionID: sessionID, version: 1)

        // 修改 a.txt
        try "modified-a".write(toFile: file1, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [
                "a.txt": entry1,
                "b.txt": entry2
            ],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }

    // MARK: - computeDiffStats

    /// 空检查点 → 空统计
    @Test
    func computeDiffStats_emptyCheckpoint_returnsEmpty() async throws {
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let inspector = RewindPreflightInspector(fileBackupStore: store)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: "s-empty",
            workspaceRoot: workspaceRoot,
            entries: [:],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)
        #expect(stats == RewindDiffStats.empty)
    }

    /// 文件内容被修改 → modifiedFiles 包含该文件，totalInsertions/Deletions 反映行差异
    @Test
    func computeDiffStats_modifiedFile_correctStats() async throws {
        let sessionID = "s-diff-modified-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/edit.txt"
        // 备份内容：2 行
        let originalContent = "line1\nline2\n"
        try originalContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 当前内容：3 行（新增 line3，修改 line1）
        let currentContent = "LINE1\nline2\nline3\n"
        try currentContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["edit.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.modifiedFiles.count == 1)
        #expect(stats.addedFiles.isEmpty)
        #expect(stats.deletedFiles.isEmpty)
        #expect(stats.filesChanged.count == 1)
        // 总行变化 > 0
        #expect(stats.totalInsertions + stats.totalDeletions > 0)
    }

    /// backupKey == nil，文件现在存在 → addedFiles 包含该文件（回滚后会被删除）
    @Test
    func computeDiffStats_newFileCreatedByAgent_inAddedFiles() async throws {
        let sessionID = "s-diff-added-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // nil backupKey = 快照时文件不存在
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: "created.txt"
        )

        // 文件现在存在（由 agent 创建）
        let filePath = workspaceRoot + "/created.txt"
        try "new content".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["created.txt": nilEntry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.addedFiles.contains(filePath))
        #expect(stats.filesChanged.contains(filePath))
        #expect(stats.modifiedFiles.isEmpty)
        #expect(stats.deletedFiles.isEmpty)
    }

    /// 文件被 agent 删除（backupKey non-nil，文件现在不存在）→ deletedFiles 包含该文件
    @Test
    func computeDiffStats_fileDeletedByAgent_inDeletedFiles() async throws {
        let sessionID = "s-diff-deleted-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/willdelete.txt"
        try "content before delete".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 模拟 agent 删除文件
        try FileManager.default.removeItem(atPath: filePath)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["willdelete.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.deletedFiles.contains(filePath))
        #expect(stats.filesChanged.contains(filePath))
        #expect(stats.modifiedFiles.isEmpty)
        #expect(stats.addedFiles.isEmpty)
    }

    /// 文件未变化 → filesChanged 为空
    @Test
    func computeDiffStats_unchangedFile_notInFilesChanged() async throws {
        let sessionID = "s-diff-unchanged-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/unchanged.txt"
        try "no changes".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["unchanged.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats == RewindDiffStats.empty)
    }
}
