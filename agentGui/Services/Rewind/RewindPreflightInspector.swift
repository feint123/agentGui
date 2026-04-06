// agentGui/Services/Rewind/RewindPreflightInspector.swift
import Foundation

// MARK: - RewindDiffStats

/// 回滚预检查结果，供确认 UI 展示变化摘要。
struct RewindDiffStats: Sendable, Equatable {
    /// 将被恢复（内容有差异）的文件绝对路径列表。
    var filesChanged: [String]

    /// 行级别统计：回滚后相对于当前状态新增的行数。
    var totalInsertions: Int

    /// 行级别统计：回滚后相对于当前状态删除的行数。
    var totalDeletions: Int

    /// 将被删除的文件（这些文件在快照时不存在，但现在存在；回滚后会被删除）。
    var addedFiles: [String]

    /// 将被恢复的文件（这些文件在快照时存在，但现在已被删除；回滚后会被重新创建）。
    var deletedFiles: [String]

    /// 内容被修改的文件（快照时存在，现在存在，但内容不同）。
    var modifiedFiles: [String]

    /// 便利构造器：空统计（无变化）
    static let empty = RewindDiffStats(
        filesChanged: [],
        totalInsertions: 0,
        totalDeletions: 0,
        addedFiles: [],
        deletedFiles: [],
        modifiedFiles: []
    )
}

// MARK: - RewindPreflightInspector

/// R-C3: 在用户触发回滚之前，异步计算回滚影响预览数据。
///
/// ## 两种操作模式
/// - `hasAnyFileChanges(checkpoint:)` — 轻量布尔检查，只 stat 不 diff，早退。用于决定是否显示确认对话框。
/// - `computeDiffStats(checkpoint:)` — 完整 diff 统计，并发对每个文件调用 StructuredDiffEngine，用于填充确认对话框。
///
/// ## 并发安全
/// `actor` 隔离；内部文件 IO 通过 `fileBackupStore`（另一个 actor）执行。
actor RewindPreflightInspector: Sendable {

    // MARK: - Dependencies

    private let fileBackupStore: FileBackupStore

    // MARK: - Init

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API (stubs — 后续 Task 填充)

    /// 轻量检查：回滚到此检查点是否会改变任何文件。
    /// 对每个被追踪文件调用 `FileBackupStore.hasFileChanged`，早退于第一个有变化的文件。
    /// 无文件变化时耗时 < 10ms（纯 stat，不读文件内容）。
    func hasAnyFileChanges(
        checkpoint: ConversationCheckpoint
    ) async throws -> Bool {
        let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

        // 空检查点 → 无变化
        guard !trackedFileBackups.isEmpty else { return false }

        for (relativePath, entry) in trackedFileBackups {
            let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)
            let changed = await fileBackupStore.hasFileChanged(
                filePath: absPath,
                sessionID: checkpoint.sessionID,
                entry: entry
            )
            if changed { return true }  // 早退
        }

        return false
    }

    /// 完整统计：计算回滚此检查点会产生多少行变化，涉及哪些文件。
    /// 并发对每个追踪文件调用 StructuredDiffEngine，返回聚合统计。
    func computeDiffStats(
        checkpoint: ConversationCheckpoint
    ) async throws -> RewindDiffStats {
        fatalError("Not implemented")
    }
}

// MARK: - Private Helpers

private extension RewindPreflightInspector {
    func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
    }
}
