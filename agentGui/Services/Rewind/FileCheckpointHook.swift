// agentGui/Services/Rewind/FileCheckpointHook.swift
import Foundation
import SwiftAnthropic

// MARK: - ActiveCheckpointAccumulator

/// 单次 agent loop 轮次内的文件备份条目缓冲区。
///
/// - 每次用户消息提交前由 `ConversationCheckpointService`（R-B1）创建并安装到
///   `ClaudeService.sessionCheckpointAccumulators[sessionID]`。
/// - `FileCheckpointHook.preExecute` 写入条目（idempotent：同一相对路径只记第一次）。
/// - R-B1 在 loop 结束后通过 `snapshot()` 读取全部条目，构建 `ConversationCheckpoint`。
actor ActiveCheckpointAccumulator: Sendable {
    /// key = 相对于 workspaceRoot 的文件路径。
    private(set) var entries: [String: FileBackupEntry] = [:]

    /// 触发此快照的用户消息 ID（由 ConversationCheckpointService 在构造时提供）。
    let messageID: UUID

    /// 快照时刻的工作目录（绝对路径）。
    let workspaceRoot: String

    init(messageID: UUID, workspaceRoot: String) {
        self.messageID = messageID
        self.workspaceRoot = workspaceRoot
    }

    /// 记录文件备份条目。同一 relativePath 的首次调用生效，后续调用幂等忽略。
    func record(relativePath: String, entry: FileBackupEntry) {
        guard entries[relativePath] == nil else { return }
        entries[relativePath] = entry
    }

    /// 返回当前所有条目的快照（不清空）。
    func snapshot() -> [String: FileBackupEntry] {
        entries
    }
}

// MARK: - FileCheckpointHook

/// 文件检查点 preExecute 钩子：在文件写入工具执行之前备份原始内容。
///
/// 触发工具：`str_replace_based_edit_tool`、`str_replace_editor`
/// 触发命令（command 字段）：`str_replace`、`create`、`write`、`insert`
/// 不触发：`view`、`read`、`open`（只读操作）、其他工具名
///
/// 并发安全：hook 为 struct（不可变），所有共享状态通过 actor 访问。
struct FileCheckpointHook: ToolExecutionHook, Sendable {

    let hookID = "file-checkpoint"

    private let fileBackupStore: FileBackupStore
    private let accumulator: ActiveCheckpointAccumulator
    private let workspaceRoot: String

    init(
        fileBackupStore: FileBackupStore,
        accumulator: ActiveCheckpointAccumulator,
        workspaceRoot: String
    ) {
        self.fileBackupStore = fileBackupStore
        self.accumulator = accumulator
        self.workspaceRoot = workspaceRoot
    }

    // MARK: - ToolExecutionHook conformance

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        // 1. 过滤：非写入操作则跳过
        guard Self.isWriteOperation(toolName: toolCall.toolName, input: toolCall.input) else {
            return .allow
        }

        // 2. 提取目标文件绝对路径
        guard let absolutePath = Self.resolveTargetFilePath(
            input: toolCall.input,
            workspaceRoot: workspaceRoot
        ) else {
            return .allow
        }

        // 3. 计算相对路径（accumulator key 和 FileBackupEntry.originalRelativePath）
        let relativePath: String
        if absolutePath.hasPrefix(workspaceRoot + "/") {
            relativePath = String(absolutePath.dropFirst(workspaceRoot.count + 1))
        } else {
            relativePath = absolutePath  // 路径在 workspaceRoot 外；使用绝对路径作 key
        }

        // 4. 幂等检查：若此 relativePath 已在 accumulator 中，无需重复备份
        let existingEntries = await accumulator.entries
        guard existingEntries[relativePath] == nil else {
            return .allow
        }

        // 5. 备份原始内容（修改前）；失败时静默通过，不 block 工具执行
        do {
            let entry = try await fileBackupStore.createBackup(
                filePath: absolutePath,
                sessionID: toolCall.sessionID,
                version: 1
            )
            let fullEntry = FileBackupEntry(
                backupKey: entry.backupKey,
                version: entry.version,
                backupTime: entry.backupTime,
                originalRelativePath: relativePath
            )
            await accumulator.record(relativePath: relativePath, entry: fullEntry)
        } catch {
            // 备份失败不阻止工具执行（容错）
        }

        return .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        .passthrough
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }

    // MARK: - Internal helpers（internal 可见性便于单元测试）

    /// 返回此次工具调用是否为文件写入操作（需要备份）。
    static func isWriteOperation(
        toolName: String,
        input: MessageResponse.Content.Input
    ) -> Bool {
        guard writeToolNames.contains(toolName) else { return false }
        let command = input["command"]?.stringValue ?? ""
        return writeCommands.contains(command)
    }

    /// 从工具 input 中提取目标文件的绝对路径。
    /// 若 path 为相对路径，以 workspaceRoot 为基础联接。
    static func resolveTargetFilePath(
        input: MessageResponse.Content.Input,
        workspaceRoot: String
    ) -> String? {
        guard let rawPath = input["path"]?.stringValue, !rawPath.isEmpty else {
            return nil
        }
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return (workspaceRoot as NSString).appendingPathComponent(rawPath)
    }

    // MARK: - Private constants

    private static let writeToolNames: Set<String> = [
        "str_replace_based_edit_tool",
        "str_replace_editor"
    ]

    private static let writeCommands: Set<String> = [
        "str_replace", "create", "write", "insert"
    ]
}
