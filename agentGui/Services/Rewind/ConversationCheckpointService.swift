// agentGui/Services/Rewind/ConversationCheckpointService.swift
import Foundation
import SwiftData

/// R-B1: 在每次用户消息触发时创建文件系统快照，持久化为 ConversationCheckpoint。
///
/// 调用时序：
///   1. Pre-loop：外部调用 `prepareAccumulator(messageID:sessionID:workspaceRoot:)` 创建
///      accumulator，写入 `ClaudeService.sessionCheckpointAccumulators`。
///   2. Post-loop：外部调用 `makeSnapshot(accumulator:sessionID:modelContext:)` 读取
///      accumulator 条目，创建 ConversationCheckpoint 并保存。
actor ConversationCheckpointService: Sendable {

    private let fileBackupStore: FileBackupStore

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API

    /// 创建新的 ActiveCheckpointAccumulator，供 FileCheckpointHook 填充。
    /// 返回值应由调用方存入 ClaudeService.sessionCheckpointAccumulators[sessionID]。
    func prepareAccumulator(
        messageID: UUID,
        sessionID: String,
        workspaceRoot: String
    ) -> ActiveCheckpointAccumulator {
        ActiveCheckpointAccumulator(messageID: messageID, workspaceRoot: workspaceRoot)
    }

    /// Post-loop: 从 accumulator 读取本轮追踪的条目，创建 ConversationCheckpoint 并 insert。
    /// ModelContext 操作在 @MainActor 上执行。
    func makeSnapshot(
        accumulator: ActiveCheckpointAccumulator,
        sessionID: String,
        modelContext: ModelContext
    ) async throws {
        let messageID = await accumulator.messageID
        let workspaceRoot = await accumulator.workspaceRoot
        let entries = await accumulator.snapshot()

        // 计算本 session 下一个 snapshotSequence
        let sequence = await nextSnapshotSequence(sessionID: sessionID, modelContext: modelContext)

        let checkpoint = try ConversationCheckpoint(
            sessionID: sessionID,
            messageID: messageID,
            snapshotSequence: sequence,
            workspaceRoot: workspaceRoot,
            trackedFileBackups: entries,
            hasFileChanges: !entries.isEmpty
        )

        await MainActor.run {
            modelContext.insert(checkpoint)
            try? modelContext.save()
        }
    }

    /// 返回 session 最近 `limit` 个快照，按 snapshotSequence 降序（最新在前）。
    func fetchCheckpoints(
        sessionID: String,
        limit: Int,
        modelContext: ModelContext
    ) async throws -> [ConversationCheckpoint] {
        let descriptor = FetchDescriptor<ConversationCheckpoint>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.snapshotSequence, order: .reverse)]
        )
        return try await MainActor.run {
            var desc = descriptor
            desc.fetchLimit = limit
            return try modelContext.fetch(desc)
        }
    }

    // MARK: - Private

    private func nextSnapshotSequence(
        sessionID: String,
        modelContext: ModelContext
    ) async -> Int {
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID },
                sortBy: [SortDescriptor(\.snapshotSequence, order: .reverse)]
            )
            var desc = descriptor
            desc.fetchLimit = 1
            let existing = try? modelContext.fetch(desc)
            return (existing?.first?.snapshotSequence ?? -1) + 1
        }
    }
}
