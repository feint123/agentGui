// agentGuiTests/FileSystemRewindCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Shared Helpers

/// 创建内存 ModelContainer（包含 ConversationCheckpoint schema）
@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 在 tmp 下创建一个 ConversationCheckpoint（含一条 FileBackupEntry）
/// relativePath / backupKey 可由调用方控制
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

// MARK: - Test Suite

@MainActor
@Suite("FileSystemRewindCoordinator Tests")
struct FileSystemRewindCoordinatorTests {

    // MARK: - Infrastructure helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Test 1: 修改后的文件被恢复为备份内容

    @Test
    func rewind_modifiedFile_restoredToBackupContent() async throws {
        // Arrange
        let sessionID = "session-restore-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        // 创建源文件（原始内容）
        let sourceFile = workspaceRoot + "/hello.txt"
        try "original content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        // 备份原始内容
        let entry = try await store.createBackup(filePath: sourceFile, sessionID: sessionID, version: 1)
        #expect(entry.backupKey != nil)

        // 修改源文件（模拟 agent 写入）
        try "modified content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        // 构造 Checkpoint
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let fullEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: 1,
            backupTime: entry.backupTime,
            originalRelativePath: "hello.txt"
        )
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["hello.txt": fullEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件内容已恢复
        let restoredContent = try String(contentsOfFile: sourceFile, encoding: .utf8)
        #expect(restoredContent == "original content")

        // Assert: result 分类正确
        #expect(result.restoredFiles == [sourceFile])
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 2: backupKey=nil 的文件（快照时不存在）在回滚时被删除

    @Test
    func rewind_newFileCreatedAfterSnapshot_deletedOnRewind() async throws {
        // Arrange
        let sessionID = "session-delete-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        // 备份时文件不存在 → backupKey = nil
        let relPath = "new_file.txt"
        let absoluteFilePath = workspaceRoot + "/" + relPath
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: relPath
        )

        // Agent 之后创建了这个文件
        try "agent created this".write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: absoluteFilePath))

        // 构造 Checkpoint
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [relPath: nilEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件已被删除
        #expect(!FileManager.default.fileExists(atPath: absoluteFilePath))

        // Assert: result 分类正确
        #expect(result.restoredFiles == [absoluteFilePath])
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 3: 文件内容与备份相同时跳过（skippedFiles）

    @Test
    func rewind_unchangedFile_addedToSkippedFilesOnly() async throws {
        // Arrange
        let sessionID = "session-skip-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        let relPath = "unchanged.txt"
        let absoluteFilePath = workspaceRoot + "/" + relPath
        try "same content".write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)

        // 备份内容与当前文件相同
        let entry = try await store.createBackup(filePath: absoluteFilePath, sessionID: sessionID, version: 1)
        // 不修改文件（模拟文件未被 agent 改动）

        let fullEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: 1,
            backupTime: entry.backupTime,
            originalRelativePath: relPath
        )

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [relPath: fullEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件内容不变
        let content = try String(contentsOfFile: absoluteFilePath, encoding: .utf8)
        #expect(content == "same content")

        // Assert: 归类为 skipped，不在 restored
        #expect(result.skippedFiles == [absoluteFilePath])
        #expect(result.restoredFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 4: 空检查点（无 tracked 文件）→ 全空结果

    @Test
    func rewind_emptyCheckpoint_returnsEmptyResult() async throws {
        let sessionID = "session-empty-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let store = FileBackupStore(baseURL: backupBaseDir)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: tmpDir.path,
            entries: [:],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 全空
        #expect(result.restoredFiles.isEmpty)
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }
}
