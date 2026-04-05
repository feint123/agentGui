// agentGui/Services/Rewind/CheckpointGCService.swift
import Foundation
import SwiftData

/// R-B2: 检查点 GC 服务。
///
/// 三种独立 GC 入口：
/// - `evictOldCheckpoints`    — 按 session 保留最近 N 个检查点，删除旧记录（SwiftData 层）
/// - `pruneOrphanBackupFiles` — 扫描磁盘备份文件，比对存活 backupKey 集合，删除孤立文件
/// - `purgeSession`           — session 删除时全量清理（SwiftData + 磁盘）
actor CheckpointGCService: Sendable {

    // MARK: - Configuration

    let defaultMaxCheckpoints: Int

    private let checkpointsBaseURL: URL

    // MARK: - Init

    init(
        defaultMaxCheckpoints: Int = 50,
        checkpointsBaseURL: URL? = nil
    ) {
        self.defaultMaxCheckpoints = defaultMaxCheckpoints
        self.checkpointsBaseURL = checkpointsBaseURL
            ?? ConfigDirectoryManager.shared.agentGuiDir
                .appendingPathComponent("checkpoints", isDirectory: true)
    }

    // MARK: - Eviction

    /// 保留指定 session 最新的 `maxCheckpoints` 条检查点，删除旧记录（FIFO）。
    /// SwiftData 操作在 @MainActor.run 内执行。
    /// 注意：此方法仅删除 SwiftData 记录；备份文件的孤立清理由 `pruneOrphanBackupFiles` 负责。
    func evictOldCheckpoints(
        sessionID: String,
        modelContext: ModelContext,
        maxCheckpoints: Int? = nil
    ) async {
        let limit = maxCheckpoints ?? defaultMaxCheckpoints
        await MainActor.run {
            do {
                let descriptor = FetchDescriptor<ConversationCheckpoint>(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.snapshotSequence, order: .forward)]
                )
                let all = try modelContext.fetch(descriptor)
                guard all.count > limit else { return }

                let toDelete = all.dropLast(limit)
                for cp in toDelete {
                    modelContext.delete(cp)
                }
                try modelContext.save()
            } catch {
                print("[CheckpointGCService] evictOldCheckpoints failed: \(error)")
            }
        }
    }

    // MARK: - Orphan Backup GC

    /// 扫描指定 session 的磁盘备份目录，删除没有任何存活 ConversationCheckpoint 引用的孤立文件。
    /// 算法：
    ///   1. 从 SwiftData 读取该 session 所有存活检查点，解码所有 backupKey 构成存活集合
    ///   2. 枚举磁盘目录中的 .bak 文件
    ///   3. 删除其 backupKey 不在存活集合中的文件
    func pruneOrphanBackupFiles(
        sessionID: String,
        modelContext: ModelContext
    ) async {
        let liveKeys = await collectLiveBackupKeys(sessionID: sessionID, modelContext: modelContext)

        let sessionDir = checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "bak" else { continue }
            let backupKey = fileURL.deletingPathExtension().lastPathComponent
            if liveKeys.contains(backupKey) { continue }
            do {
                try fm.removeItem(at: fileURL)
            } catch {
                print("[CheckpointGCService] Failed to remove orphan backup \(fileURL.lastPathComponent): \(error)")
            }
        }

        cleanEmptyShardDirs(in: sessionDir)
    }

    // MARK: - Session Purge

    /// session 被删除时调用：删除该 session 的所有 ConversationCheckpoint（SwiftData）
    /// 并清空磁盘上的备份目录。
    func purgeSession(sessionID: String, modelContext: ModelContext) async {
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID }
            )
            guard let checkpoints = try? modelContext.fetch(descriptor) else { return }
            for cp in checkpoints {
                modelContext.delete(cp)
            }
            try? modelContext.save()
        }

        let sessionDir = checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    /// 对所有在 SwiftData 中有检查点记录的 session 执行 eviction，并全局 prune 孤立备份。
    /// 建议在 app 启动后台异步调用，不阻塞启动路径。
    func pruneAllSessions(modelContext: ModelContext, maxCheckpointsPerSession: Int? = nil) async {
        let limit = maxCheckpointsPerSession ?? defaultMaxCheckpoints

        let sessionIDs: [String] = await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>()
            guard let all = try? modelContext.fetch(descriptor) else { return [] }
            return Array(Set(all.map(\.sessionID)))
        }

        for sid in sessionIDs {
            await evictOldCheckpoints(sessionID: sid, modelContext: modelContext, maxCheckpoints: limit)
        }

        for sid in sessionIDs {
            await pruneOrphanBackupFiles(sessionID: sid, modelContext: modelContext)
        }

        await purgeOrphanSessionDirs(liveSessionIDs: Set(sessionIDs))
    }

    // MARK: - Private Helpers

    /// 从 SwiftData 取出该 session 所有检查点，解码 JSON 并收集所有非 nil backupKey。
    private func collectLiveBackupKeys(
        sessionID: String,
        modelContext: ModelContext
    ) async -> Set<String> {
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID }
            )
            guard let checkpoints = try? modelContext.fetch(descriptor) else { return Set() }
            var keys = Set<String>()
            for cp in checkpoints {
                guard let backups = try? cp.decodedTrackedFileBackups() else { continue }
                for entry in backups.values {
                    if let key = entry.backupKey {
                        keys.insert(key)
                    }
                }
            }
            return keys
        }
    }

    /// 删除 shardDir 内的空目录，防止残留空文件夹。
    private func cleanEmptyShardDirs(in sessionDir: URL) {
        let fm = FileManager.default
        guard let shardDirs = try? fm.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in shardDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 删除 checkpointsBaseURL/{sessionID} 目录中不在 liveSessionIDs 集合内的条目。
    private func purgeOrphanSessionDirs(liveSessionIDs: Set<String>) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: checkpointsBaseURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let sid = entry.lastPathComponent
            if !liveSessionIDs.contains(sid) {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
