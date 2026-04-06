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
        let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

        guard !trackedFileBackups.isEmpty else { return .empty }

        let diffEngine = StructuredDiffEngine()

        // 并发对每个文件计算 diff
        var perFileResults: [RewindFileResult] = []

        await withTaskGroup(of: RewindFileResult?.self) { group in
            for (relativePath, entry) in trackedFileBackups {
                group.addTask {
                    await self.computeFileResult(
                        relativePath: relativePath,
                        entry: entry,
                        checkpoint: checkpoint,
                        diffEngine: diffEngine
                    )
                }
            }
            for await result in group {
                if let r = result {
                    perFileResults.append(r)
                }
            }
        }

        // 聚合结果
        var filesChanged: [String] = []
        var totalInsertions = 0
        var totalDeletions = 0
        var addedFiles: [String] = []
        var deletedFiles: [String] = []
        var modifiedFiles: [String] = []

        for r in perFileResults {
            filesChanged.append(r.absolutePath)
            totalInsertions += r.insertions
            totalDeletions += r.deletions
            switch r.category {
            case .added:    addedFiles.append(r.absolutePath)
            case .deleted:  deletedFiles.append(r.absolutePath)
            case .modified: modifiedFiles.append(r.absolutePath)
            }
        }

        return RewindDiffStats(
            filesChanged: filesChanged,
            totalInsertions: totalInsertions,
            totalDeletions: totalDeletions,
            addedFiles: addedFiles,
            deletedFiles: deletedFiles,
            modifiedFiles: modifiedFiles
        )
    }

    // MARK: - Private Helpers (inside actor body)

    private enum FileChangeCategory {
        case added    // 快照时不存在，现在存在 → 回滚后会被删除
        case deleted  // 快照时存在，现在不存在 → 回滚后会被恢复
        case modified // 快照时存在，现在也存在，但内容不同
    }

    private struct RewindFileResult {
        let absolutePath: String
        let insertions: Int   // 回滚后新增的行数（备份比当前多的行）
        let deletions: Int    // 回滚后删除的行数（当前比备份多的行）
        let category: FileChangeCategory
    }

    /// 对单个文件计算 diff 统计。返回 nil 表示文件未变化或计算出错。
    private func computeFileResult(
        relativePath: String,
        entry: FileBackupEntry,
        checkpoint: ConversationCheckpoint,
        diffEngine: StructuredDiffEngine
    ) async -> RewindFileResult? {
        let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)
        let fm = FileManager.default

        if let backupKey = entry.backupKey {
            // 文件在快照时存在
            let backupContent = await fileBackupStore.readBackupContent(
                backupKey: backupKey,
                sessionID: checkpoint.sessionID
            )

            let currentExists = fm.fileExists(atPath: absPath)

            if !currentExists {
                // 文件被 agent 删除 → 回滚后会被恢复 (category: .deleted)
                guard let backup = backupContent else { return nil }
                guard let diff = try? diffEngine.build(
                    relativePath: relativePath,
                    absolutePath: absPath,
                    kind: .add,
                    baseContent: nil,       // 当前无内容
                    stagedContent: backup   // 备份 = 恢复目标
                ) else { return nil }
                return RewindFileResult(
                    absolutePath: absPath,
                    insertions: diff.summary.additions,
                    deletions: diff.summary.deletions,
                    category: .deleted
                )
            }

            // 文件存在，检查内容是否变化
            guard await fileBackupStore.hasFileChanged(
                filePath: absPath,
                sessionID: checkpoint.sessionID,
                entry: entry
            ) else {
                return nil  // 未变化，跳过
            }

            let currentContent: String? = try? String(contentsOfFile: absPath, encoding: .utf8)

            // 内容已变化 → 计算 diff（baseContent = 备份，stagedContent = 当前）
            guard let diff = try? diffEngine.build(
                relativePath: relativePath,
                absolutePath: absPath,
                kind: .modify,
                baseContent: backupContent,   // 备份（旧）
                stagedContent: currentContent // 当前（新）
            ) else { return nil }

            // insertions = 备份比当前多的行（回滚后会出现）= diff.summary.deletions（从 base→staged 视角）
            // deletions  = 当前比备份多的行（回滚后会消失）= diff.summary.additions
            return RewindFileResult(
                absolutePath: absPath,
                insertions: diff.summary.deletions,
                deletions: diff.summary.additions,
                category: .modified
            )

        } else {
            // backupKey == nil：文件在快照时不存在
            guard fm.fileExists(atPath: absPath) else {
                return nil  // 快照时不存在，现在也不存在 → 无变化
            }

            // 文件由 agent 新增 → 回滚后会被删除 (category: .added)
            let currentContent = try? String(contentsOfFile: absPath, encoding: .utf8)
            guard let diff = try? diffEngine.build(
                relativePath: relativePath,
                absolutePath: absPath,
                kind: .delete,
                baseContent: currentContent,  // 当前（将被删除）
                stagedContent: nil            // 快照时不存在
            ) else { return nil }

            // 从恢复视角：回滚后会删除所有当前行
            return RewindFileResult(
                absolutePath: absPath,
                insertions: 0,
                deletions: diff.summary.deletions,
                category: .added
            )
        }
    }
}

// MARK: - Private Helpers

private extension RewindPreflightInspector {
    func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
    }
}
