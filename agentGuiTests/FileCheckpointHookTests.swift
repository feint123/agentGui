// agentGuiTests/FileCheckpointHookTests.swift
import Foundation
import Testing
import SwiftAnthropic
@testable import agentGui

@Suite("FileCheckpointHook Tests")
struct FileCheckpointHookTests {

    // MARK: - ActiveCheckpointAccumulator

    @Test
    func accumulator_record_storesEntry() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let entry = FileBackupEntry(backupKey: "abc", version: 1, backupTime: Date(), originalRelativePath: "a.swift")

        await acc.record(relativePath: "a.swift", entry: entry)

        let entries = await acc.entries
        #expect(entries["a.swift"] != nil)
        #expect(entries["a.swift"]?.backupKey == "abc")
    }

    @Test
    func accumulator_record_idempotent_firstWriteWins() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let e1 = FileBackupEntry(backupKey: "first", version: 1, backupTime: Date(), originalRelativePath: "a.swift")
        let e2 = FileBackupEntry(backupKey: "second", version: 2, backupTime: Date(), originalRelativePath: "a.swift")

        await acc.record(relativePath: "a.swift", entry: e1)
        await acc.record(relativePath: "a.swift", entry: e2)   // second call is no-op

        let entries = await acc.entries
        #expect(entries["a.swift"]?.backupKey == "first")
    }

    @Test
    func accumulator_snapshot_returnsAllEntries() async {
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")
        let e1 = FileBackupEntry(backupKey: "k1", version: 1, backupTime: Date(), originalRelativePath: "a.swift")
        let e2 = FileBackupEntry(backupKey: "k2", version: 1, backupTime: Date(), originalRelativePath: "b.swift")

        await acc.record(relativePath: "a.swift", entry: e1)
        await acc.record(relativePath: "b.swift", entry: e2)

        let snap = await acc.snapshot()
        #expect(snap.count == 2)
        #expect(snap["a.swift"] != nil)
        #expect(snap["b.swift"] != nil)
    }

    @Test
    func accumulator_concurrentRecords_noDataRace() async {
        // 验证并发写入不丢条目（actor 隔离保证）
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: "/ws")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let e = FileBackupEntry(
                        backupKey: "key\(i)",
                        version: 1,
                        backupTime: Date(),
                        originalRelativePath: "file\(i).swift"
                    )
                    await acc.record(relativePath: "file\(i).swift", entry: e)
                }
            }
        }

        let entries = await acc.entries
        #expect(entries.count == 20)
    }

    // MARK: - isWriteOperation

    @Test
    func isWriteOperation_strReplaceTool_writeCommands_returnsTrue() {
        let writeCommands = ["str_replace", "create", "write", "insert"]
        for cmd in writeCommands {
            let result = FileCheckpointHook.isWriteOperation(
                toolName: "str_replace_based_edit_tool",
                input: ["command": .string(cmd), "path": .string("/f.swift")]
            )
            #expect(result == true, "Expected true for command: \(cmd)")
        }
    }

    @Test
    func isWriteOperation_strReplaceTool_readCommands_returnsFalse() {
        let readCommands = ["view", "read", "open"]
        for cmd in readCommands {
            let result = FileCheckpointHook.isWriteOperation(
                toolName: "str_replace_based_edit_tool",
                input: ["command": .string(cmd), "path": .string("/f.swift")]
            )
            #expect(result == false, "Expected false for command: \(cmd)")
        }
    }

    @Test
    func isWriteOperation_otherTool_returnsFalse() {
        let result = FileCheckpointHook.isWriteOperation(
            toolName: "bash",
            input: ["command": .string("command"), "cmd": .string("echo hi")]
        )
        #expect(result == false)
    }

    @Test
    func resolveTargetFilePath_absolutePath_returnsAsIs() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["path": .string("/workspace/src/main.swift")],
            workspaceRoot: "/workspace"
        )
        #expect(path == "/workspace/src/main.swift")
    }

    @Test
    func resolveTargetFilePath_relativePath_joinsWithWorkspaceRoot() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["path": .string("src/main.swift")],
            workspaceRoot: "/workspace"
        )
        #expect(path == "/workspace/src/main.swift")
    }

    @Test
    func resolveTargetFilePath_missingPath_returnsNil() {
        let path = FileCheckpointHook.resolveTargetFilePath(
            input: ["command": .string("str_replace")],
            workspaceRoot: "/workspace"
        )
        #expect(path == nil)
    }

    // MARK: - preExecute integration

    /// 使用临时目录创建真实的 FileBackupStore，验证 preExecute 实际写入备份。
    private func makeTempStore() throws -> (FileBackupStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (FileBackupStore(baseURL: tmp.appendingPathComponent("checkpoints")), tmp)
    }

    @Test
    func preExecute_writeCommand_backupsFileAndRecordsEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let wsRoot = tmp.path
        let targetFile = tmp.appendingPathComponent("src/main.swift")
        try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original content".write(to: targetFile, atomically: true, encoding: .utf8)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: wsRoot)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: wsRoot
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-1",
            toolName: "str_replace_based_edit_tool",
            input: [
                "command": .string("str_replace"),
                "path": .string(targetFile.path)
            ],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        // 1. 总是 allow
        switch decision {
        case .allow: break
        default: Issue.record("Expected .allow, got \(decision)")
        }

        // 2. accumulator 中有条目
        let entries = await acc.entries
        #expect(entries.count == 1)

        // 3. 条目的 backupKey 非 nil（文件存在）
        let relativePath = "src/main.swift"
        let entry = try #require(entries[relativePath])
        #expect(entry.backupKey != nil)
    }

    @Test
    func preExecute_writeCommand_nonexistentFile_recordsNilBackupKey() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-2",
            toolName: "str_replace_based_edit_tool",
            input: [
                "command": .string("create"),
                "path": .string(tmp.appendingPathComponent("new.swift").path)
            ],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        let decision = await hook.preExecute(toolCall: preview)

        switch decision {
        case .allow: break
        default: Issue.record("Expected .allow")
        }

        let entries = await acc.entries
        #expect(entries.count == 1)
        // 文件不存在，backupKey 应为 nil
        let entry = try #require(entries["new.swift"])
        #expect(entry.backupKey == nil)
    }

    @Test
    func preExecute_sameFileTwice_idempotent_noDoubleBackup() async throws {
        let (store, tmp) = try makeTempStore()
        let targetFile = tmp.appendingPathComponent("dup.swift")
        try "v1".write(to: targetFile, atomically: true, encoding: .utf8)

        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-3",
            toolName: "str_replace_based_edit_tool",
            input: ["command": .string("str_replace"), "path": .string(targetFile.path)],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        // 假设工具调用了两次（不常见，但 hook 应幂等）
        _ = await hook.preExecute(toolCall: preview)
        try "v2 (modified)".write(to: targetFile, atomically: true, encoding: .utf8)
        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        // 只有 1 条条目（first-write-wins）
        #expect(entries.count == 1)
        // backupKey 对应 v1 内容
        let entry = try #require(entries["dup.swift"])
        #expect(entry.backupKey != nil)
    }

    @Test
    func preExecute_readCommand_skipped_noEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-4",
            toolName: "str_replace_based_edit_tool",
            input: ["command": .string("view"), "path": .string("/tmp/some.swift")],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        #expect(entries.isEmpty)
    }

    @Test
    func preExecute_bashTool_skipped_noEntry() async throws {
        let (store, tmp) = try makeTempStore()
        let acc = ActiveCheckpointAccumulator(messageID: UUID(), workspaceRoot: tmp.path)
        let hook = FileCheckpointHook(
            fileBackupStore: store,
            accumulator: acc,
            workspaceRoot: tmp.path
        )

        let preview = ToolCallPreview(
            toolCallId: "tc-5",
            toolName: "bash",
            input: ["command": .string("echo hello")],
            sessionID: "session-A",
            executionContext: .mainAgent
        )

        _ = await hook.preExecute(toolCall: preview)

        let entries = await acc.entries
        #expect(entries.isEmpty)
    }
}
