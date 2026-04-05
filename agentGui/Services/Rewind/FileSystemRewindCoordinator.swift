// agentGui/Services/Rewind/FileSystemRewindCoordinator.swift
import Foundation
import SwiftData

// MARK: - Notification.Name

extension Notification.Name {
    /// 文件系统恢复完成后发出。
    /// - object: sessionID (String)
    /// - userInfo: ["restoredFiles": [String]] — 实际被恢复的绝对路径列表
    static let rewindDidRestoreFiles = Notification.Name("agentGui.rewindDidRestoreFiles")
}

// MARK: - FileSystemRewindCoordinator

/// R-C2: 将工作区文件系统恢复到指定 ConversationCheckpoint 所记录的状态。
///
/// ## 职责边界
/// - 只负责文件系统恢复，不截断对话（R-C1）
/// - 不负责取消 agent loop（R-C4 先完成）
/// - 恢复为 non-atomic：每文件独立容错，单文件失败不影响其他文件
///
/// ## 并发安全
/// `@MainActor`：SwiftData `@Model` 只在 MainActor 访问；
/// 文件 IO 通过 `await fileBackupStore.*` 委托给 `FileBackupStore` actor。
@MainActor
final class FileSystemRewindCoordinator {

    // MARK: - Types

    struct RewindResult {
        /// 实际被恢复的文件绝对路径列表（内容有差异并成功恢复）。
        var restoredFiles: [String]
        /// 与备份内容相同、无需恢复的文件绝对路径列表。
        var skippedFiles: [String]
        /// 恢复失败的文件绝对路径及对应错误。
        var failedFiles: [(path: String, error: Error)]
    }

    // MARK: - Dependencies

    private let fileBackupStore: FileBackupStore

    // MARK: - Init

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API

    /// 将文件系统恢复到 `checkpoint` 记录的状态。
    ///
    /// - Parameter checkpoint: 目标检查点，由 `ConversationCheckpointService` 创建。
    /// - Returns: 包含已恢复、已跳过、已失败文件列表的结构体。
    /// - Throws: `ConversationCheckpointError` 若 JSON 解码失败（极少，备份元数据损坏）。
    func rewind(to checkpoint: ConversationCheckpoint) async throws -> RewindResult {
        // 1. 解码 trackedFileBackupsJSON（若 JSON 损坏则 throw，这是唯一 throw 路径）
        let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

        var restoredFiles: [String] = []
        var skippedFiles: [String] = []
        var failedFiles: [(path: String, error: Error)] = []

        // 2. 逐文件处理（non-atomic：单文件失败不影响其他文件）
        for (relativePath, entry) in trackedFileBackups {
            let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)

            do {
                let changed = await fileBackupStore.hasFileChanged(
                    filePath: absPath,
                    sessionID: checkpoint.sessionID,
                    entry: entry
                )

                if changed {
                    try await fileBackupStore.restoreFile(
                        filePath: absPath,
                        sessionID: checkpoint.sessionID,
                        from: entry
                    )
                    restoredFiles.append(absPath)
                } else {
                    skippedFiles.append(absPath)
                }
            } catch {
                failedFiles.append((path: absPath, error: error))
            }
        }

        // 3. 发出通知，让 Editor 视图、ChangeReview 视图刷新
        NotificationCenter.default.post(
            name: .rewindDidRestoreFiles,
            object: checkpoint.sessionID,
            userInfo: ["restoredFiles": restoredFiles]
        )

        return RewindResult(
            restoredFiles: restoredFiles,
            skippedFiles: skippedFiles,
            failedFiles: failedFiles
        )
    }
}

// MARK: - Private Helpers

private extension FileSystemRewindCoordinator {

    /// 将 relativePath（字典 key）解析为绝对路径。
    /// relativePath 以 "/" 开头时视为绝对路径（文件在 workspaceRoot 之外）。
    func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
    }
}
