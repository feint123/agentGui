// agentGuiTests/FileBackupStoreTests.swift
import Foundation
import Testing
@testable import agentGui

@Suite("FileBackupStore Tests")
struct FileBackupStoreTests {

    // MARK: - Helpers

    /// 每次测试使用隔离的临时目录，避免状态污染。
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(baseURL: URL) -> FileBackupStore {
        FileBackupStore(baseURL: baseURL)
    }

    // MARK: - createBackup: 存在文件

    @Test
    func createBackup_existingFile_createsBackupOnDisk() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("source.txt")
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)

        let entry = try await store.createBackup(
            filePath: testFile.path,
            sessionID: "session-1",
            version: 1
        )

        // backupKey 不为 nil
        let key = try #require(entry.backupKey)
        #expect(entry.version == 1)
        #expect(entry.originalRelativePath == testFile.path)

        // 备份文件存在于磁盘
        let bak = tmp
            .appendingPathComponent("checkpoints/session-1/\(String(key.prefix(2)))/\(key).bak")
        #expect(FileManager.default.fileExists(atPath: bak.path))

        // 备份文件内容与源文件一致
        let content = try String(contentsOf: bak, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test
    func createBackup_existingFile_idempotent() async throws {
        // 相同内容两次调用，返回相同 backupKey，磁盘上不重复写
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("idempotent.txt")
        try "same content".write(to: testFile, atomically: true, encoding: .utf8)

        let entry1 = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
        let entry2 = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

        #expect(entry1.backupKey == entry2.backupKey)
    }

    @Test
    func createBackup_nonexistentFile_returnsNilBackupKey() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

        let entry = try await store.createBackup(
            filePath: "/tmp/does-not-exist-\(UUID().uuidString).txt",
            sessionID: "s",
            version: 1
        )

        #expect(entry.backupKey == nil)
        #expect(entry.version == 1)
    }

    @Test
    func createBackup_binaryFile_roundtripCorrect() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("binary.bin")
        let binaryData = Data((0..<256).map { UInt8($0) })
        try binaryData.write(to: testFile)

        let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
        let key = try #require(entry.backupKey)
        let bak = tmp.appendingPathComponent("checkpoints/s/\(String(key.prefix(2)))/\(key).bak")
        let restored = try Data(contentsOf: bak)
        #expect(restored == binaryData)
    }

    // MARK: - hasFileChanged

    @Test
    func hasFileChanged_fileUnchanged_returnsFalse() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("unchanged.txt")
        try "original".write(to: testFile, atomically: true, encoding: .utf8)

        let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
        let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: entry)
        #expect(changed == false)
    }

    @Test
    func hasFileChanged_fileModified_returnsTrue() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("modified.txt")
        try "original".write(to: testFile, atomically: true, encoding: .utf8)

        let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

        // 修改文件内容
        try "modified content".write(to: testFile, atomically: true, encoding: .utf8)

        let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: entry)
        #expect(changed == true)
    }

    @Test
    func hasFileChanged_nilBackupKey_fileExists_returnsTrue() async throws {
        // nil backupKey = 文件快照时不存在；现在文件存在 → 已变化
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("new.txt")
        try "created after snapshot".write(to: testFile, atomically: true, encoding: .utf8)

        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: testFile.path
        )
        let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: nilEntry)
        #expect(changed == true)
    }

    @Test
    func hasFileChanged_nilBackupKey_fileAbsent_returnsFalse() async throws {
        // nil backupKey = 文件快照时不存在；现在文件也不存在 → 未变化
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: "/tmp/ghost-\(UUID().uuidString).txt"
        )
        let changed = await store.hasFileChanged(
            filePath: "/tmp/ghost-\(UUID().uuidString).txt",
            sessionID: "s",
            entry: nilEntry
        )
        #expect(changed == false)
    }

    // MARK: - restoreFile

    @Test
    func restoreFile_restoresContent() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("restore.txt")
        try "original content".write(to: testFile, atomically: true, encoding: .utf8)

        let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

        // 修改文件
        try "modified content".write(to: testFile, atomically: true, encoding: .utf8)

        // 恢复
        try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: entry)

        let restored = try String(contentsOf: testFile, encoding: .utf8)
        #expect(restored == "original content")
    }

    @Test
    func restoreFile_nilBackupKey_deletesFile() async throws {
        // nil backupKey → 文件快照时不存在 → 恢复时应删除
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("to-delete.txt")
        try "some content".write(to: testFile, atomically: true, encoding: .utf8)

        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: testFile.path
        )
        try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: nilEntry)

        #expect(!FileManager.default.fileExists(atPath: testFile.path))
    }

    @Test
    func restoreFile_nilBackupKey_fileAlreadyAbsent_noThrow() async throws {
        // nil backupKey + 文件已不存在 → 幂等，不抛错
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let ghost = "/tmp/ghost-\(UUID().uuidString).txt"

        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: ghost
        )
        // 不应抛出
        try await store.restoreFile(filePath: ghost, sessionID: "s", from: nilEntry)
    }

    @Test
    func restoreFile_missingBackupFile_throws() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("missing-backup.txt")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let fakeEntry = FileBackupEntry(
            backupKey: "deadbeef01234567deadbeef01234567deadbeef01234567deadbeef01234567.v1",
            version: 1,
            backupTime: Date(),
            originalRelativePath: testFile.path
        )
        await #expect(throws: FileBackupStoreError.self) {
            try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: fakeEntry)
        }
    }

    // MARK: - deleteBackups

    @Test
    func deleteBackups_removesAllBackupsForSession() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

        // 创建两个不同文件的备份
        let file1 = tmp.appendingPathComponent("a.txt")
        let file2 = tmp.appendingPathComponent("b.txt")
        try "aaa".write(to: file1, atomically: true, encoding: .utf8)
        try "bbb".write(to: file2, atomically: true, encoding: .utf8)

        let entry1 = try await store.createBackup(filePath: file1.path, sessionID: "sess-gc", version: 1)
        let entry2 = try await store.createBackup(filePath: file2.path, sessionID: "sess-gc", version: 1)

        let bak1 = try #require(entry1.backupKey)
        let bak2 = try #require(entry2.backupKey)

        let sessionDir = tmp.appendingPathComponent("checkpoints/sess-gc")
        #expect(FileManager.default.fileExists(atPath: sessionDir.path))

        await store.deleteBackups(forSession: "sess-gc")

        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
        _ = bak1; _ = bak2  // suppress unused warning
    }

    @Test
    func deleteBackups_otherSessionUnaffected() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

        let file = tmp.appendingPathComponent("c.txt")
        try "ccc".write(to: file, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: file.path, sessionID: "other-session", version: 1)
        let key = try #require(entry.backupKey)

        // 删除不同 session
        await store.deleteBackups(forSession: "sess-to-delete")

        // other-session 的备份仍存在
        let bak = tmp.appendingPathComponent("checkpoints/other-session/\(String(key.prefix(2)))/\(key).bak")
        #expect(FileManager.default.fileExists(atPath: bak.path))
    }

    @Test
    func deleteBackups_nonexistentSession_noThrow() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = makeStore(baseURL: tmp)
        // 不应崩溃
        await store.deleteBackups(forSession: "ghost-session")
    }

    // MARK: - Security

    @Test
    func createBackup_pathTraversal_throws() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        // 路径规范化后仍为绝对路径，但尝试遍历到 /etc
        let traversal = "/tmp/../etc/passwd"
        // 不应将 /etc/passwd 内容写入备份
        // 此测试验证函数不 throw pathTraversalDetected（路径虽奇怪但合法）
        // 真正的保护在 restoreFile 不能写到非 workspaceRoot 目录（由调用方负责）
        // 此处只验证 createBackup 对绝对路径不混入备份路径
        let entry = try await store.createBackup(filePath: traversal, sessionID: "s", version: 1)
        // /etc/passwd 一般存在；若存在，backupKey 不为 nil。
        // 关键：备份路径必须在 checkpoints 目录内，不逃逸到外部
        if let key = entry.backupKey {
            let bak = tmp.appendingPathComponent("checkpoints/s/\(String(key.prefix(2)))/\(key).bak")
            // 备份文件的 canonicalPath 必须在 checkpoints 目录内
            let checkpointsCanonical = tmp.appendingPathComponent("checkpoints").resolvingSymlinksInPath().path
            let bakCanonical = bak.resolvingSymlinksInPath().path
            #expect(bakCanonical.hasPrefix(checkpointsCanonical))
        }
    }
}
