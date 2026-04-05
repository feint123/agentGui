import Foundation
import SwiftData

/// 单个被追踪文件的备份元数据。
/// 存储为 JSON 字符串（ConversationCheckpoint.trackedFileBackupsJSON 的 value 类型）。
struct FileBackupEntry: Codable, Sendable, Equatable {
    /// 内容寻址备份文件的键（即 sha256 哈希值）。
    /// nil 表示该文件在此快照时刻不存在（新增文件的 pre-creation 状态）。
    var backupKey: String?

    /// 备份版本号，同一轮次内单调递增。
    var version: Int

    /// 备份写入时刻。
    var backupTime: Date

    /// 文件相对于 workspaceRoot 的路径（如 "src/main.swift"）。
    var originalRelativePath: String
}

extension FileBackupEntry {
    /// 该文件在快照时刻是否存在。
    var fileExistedAtSnapshot: Bool { backupKey != nil }
}

// MARK: - ConversationCheckpoint

/// 一次用户消息触发的文件系统状态快照。
/// 与 Message 通过 messageID（软引用）关联，不使用 @Relationship，
/// 防止对话截断时级联误删检查点。
@Model
final class ConversationCheckpoint {
    /// 检查点唯一标识。
    var id: UUID

    /// 所属会话 ID（对应 Session.sessionId）。
    var sessionID: String

    /// 触发此快照的用户消息 ID（对应 Message.id）。
    var messageID: UUID

    /// 会话内单调递增序号，用于排序和 GC eviction（FIFO）。
    var snapshotSequence: Int

    /// 快照创建时刻的工作目录绝对路径（对应 Session.workingDirectory）。
    var workspaceRoot: String

    /// 检查点创建时刻。
    var createdAt: Date

    /// key = 文件相对路径（相对于 workspaceRoot），value = FileBackupEntry JSON。
    /// 使用 JSON 字符串存储，避免引入额外 SwiftData 子模型。
    var trackedFileBackupsJSON: String

    /// 快速标志：此检查点是否有任何文件被追踪并发生变化。
    /// 避免每次都解码 trackedFileBackupsJSON 进行判断。
    var hasFileChanges: Bool

    init(
        id: UUID = UUID(),
        sessionID: String,
        messageID: UUID,
        snapshotSequence: Int,
        workspaceRoot: String,
        trackedFileBackups: [String: FileBackupEntry] = [:],
        hasFileChanges: Bool = false,
        createdAt: Date = Date()
    ) throws {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.snapshotSequence = snapshotSequence
        self.workspaceRoot = workspaceRoot
        self.hasFileChanges = hasFileChanges
        self.createdAt = createdAt
        self.trackedFileBackupsJSON = try Self.encode(trackedFileBackups)
    }
}

// MARK: - JSON Helpers

extension ConversationCheckpoint {
    /// 解码 trackedFileBackupsJSON → [relativePath: FileBackupEntry]。
    func decodedTrackedFileBackups() throws -> [String: FileBackupEntry] {
        guard let data = trackedFileBackupsJSON.data(using: .utf8) else {
            throw ConversationCheckpointError.invalidUTF8JSON
        }
        return try JSONDecoder().decode([String: FileBackupEntry].self, from: data)
    }

    /// 编码并更新 trackedFileBackupsJSON。
    func setTrackedFileBackups(_ backups: [String: FileBackupEntry]) throws {
        trackedFileBackupsJSON = try Self.encode(backups)
        hasFileChanges = !backups.isEmpty
    }

    private static func encode(_ backups: [String: FileBackupEntry]) throws -> String {
        let data = try JSONEncoder().encode(backups)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConversationCheckpointError.encodingFailed
        }
        return string
    }
}

// MARK: - Error

enum ConversationCheckpointError: Error, Sendable {
    case invalidUTF8JSON
    case encodingFailed
}
