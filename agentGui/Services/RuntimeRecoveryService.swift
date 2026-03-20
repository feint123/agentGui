import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class RuntimeRecoveryService {
    private let persistenceCoordinator: PersistenceCoordinator
    private(set) var activeSnapshots: [RecoverySnapshot] = []

    init(persistenceCoordinator: PersistenceCoordinator = .shared) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    func loadRecoverySummary(from modelContext: ModelContext) throws -> RecoverySummary {
        try refresh(from: modelContext)
        return RecoverySummary(items: activeSnapshots)
    }

    func refresh(from modelContext: ModelContext) throws {
        var activeKeys = Set<String>()

        let messages = try modelContext.fetch(FetchDescriptor<Message>())
        for message in messages where message.direction == .agent && message.status == .pending {
            guard let sessionId = message.session?.sessionId else { continue }
            let key = snapshotKey(kind: .messageGeneration, identifier: message.id.uuidString)
            activeKeys.insert(key)
            let summary = message.textContent?.isEmpty == false
                ? "未完成的回复：\(String((message.textContent ?? "").prefix(80)))"
                : "上一轮回复在生成过程中被中断"
            try upsertSnapshot(
                sessionId: sessionId,
                sourceKind: .messageGeneration,
                sourceIdentifier: message.id.uuidString,
                summaryText: summary,
                metadata: ["messageId": message.id.uuidString],
                modelContext: modelContext
            )
        }

        let allSnapshots = try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
        var needsSave = false
        for snapshot in allSnapshots where snapshot.handlingState.isVisible {
            if snapshot.sourceKind == .bashTask {
                continue
            }
            let key = snapshotKey(kind: snapshot.sourceKind, identifier: snapshot.sourceIdentifier)
            if !activeKeys.contains(key) {
                modelContext.delete(snapshot)
                needsSave = true
            }
        }

        if needsSave {
            try persistenceCoordinator.save(
                modelContext,
                domain: .sessionTaskState,
                userMessage: "恢复摘要同步未成功保存"
            )
        }

        activeSnapshots = try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
            .filter { $0.handlingState.isVisible }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func recoveryItems(for sessionId: String) -> [RecoverySnapshot] {
        activeSnapshots.filter { $0.sessionId == sessionId }
    }

    func markViewed(_ snapshot: RecoverySnapshot, in modelContext: ModelContext) throws {
        snapshot.handlingState = .viewed
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "恢复状态未成功保存"
        )
        try refresh(from: modelContext)
    }

    func markInterrupted(_ snapshot: RecoverySnapshot, in modelContext: ModelContext) throws {
        try normalizeSource(snapshot, in: modelContext, terminalAction: .interrupted)
        snapshot.handlingState = .interrupted
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "恢复标记未成功保存"
        )
        try refresh(from: modelContext)
    }

    func clear(_ snapshot: RecoverySnapshot, in modelContext: ModelContext) throws {
        try normalizeSource(snapshot, in: modelContext, terminalAction: .cleared)
        snapshot.handlingState = .cleared
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "恢复清理未成功保存"
        )
        try refresh(from: modelContext)
    }

    func normalizeBackgroundTaskRuns(in modelContext: ModelContext) throws {
        let runs = try modelContext.fetch(FetchDescriptor<BackgroundAgentTaskRun>())
        var needsSave = false
        for run in runs where run.status == .running {
            run.status = .interrupted
            run.finishedAt = Date()
            needsSave = true
        }

        if needsSave {
            try persistenceCoordinator.save(
                modelContext,
                domain: .sessionTaskState,
                userMessage: "后台任务恢复状态未成功保存"
            )
        }
    }

    private enum TerminalAction {
        case interrupted
        case cleared
    }

    private func normalizeSource(_ snapshot: RecoverySnapshot, in modelContext: ModelContext, terminalAction: TerminalAction) throws {
        switch snapshot.sourceKind {
        case .messageGeneration:
            guard let messageID = UUID(uuidString: snapshot.sourceIdentifier) else { return }
            let messages = try modelContext.fetch(FetchDescriptor<Message>())
            guard let message = messages.first(where: { $0.id == messageID }), message.status == .pending else { return }
            message.status = .failed
            message.errorMessage = terminalAction == .interrupted ? "消息生成在恢复前被标记为中断。" : "消息生成恢复现场已清理。"
            if message.textContent?.isEmpty ?? true {
                message.textContent = terminalAction == .interrupted ? "已标记为中断" : "已清理未完成回复"
            }
        case .bashTask:
            break
        }
    }

    private func upsertSnapshot(
        sessionId: String,
        sourceKind: RecoverySourceKind,
        sourceIdentifier: String,
        summaryText: String,
        metadata: [String: String],
        modelContext: ModelContext
    ) throws {
        let snapshots = try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
        if let existing = snapshots.first(where: {
            $0.sessionId == sessionId &&
            $0.sourceKind == sourceKind &&
            $0.sourceIdentifier == sourceIdentifier
        }) {
            existing.summaryText = summaryText
            existing.metadataJSON = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
            existing.updatedAt = Date()
            return
        }

        let snapshot = RecoverySnapshot(
            sessionId: sessionId,
            sourceKind: sourceKind,
            sourceIdentifier: sourceIdentifier,
            summaryText: summaryText,
            metadata: metadata
        )
        modelContext.insert(snapshot)
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "恢复摘要未成功保存"
        )
    }

    private func snapshotKey(kind: RecoverySourceKind, identifier: String) -> String {
        "\(kind.rawValue):\(identifier)"
    }
}