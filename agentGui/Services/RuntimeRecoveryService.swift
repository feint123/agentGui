import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class RuntimeRecoveryService {
    struct RuntimeRecoveryItem: Equatable, Sendable, Identifiable {
        let id: String
        let sessionID: String
        let titleText: String
        let summaryText: String
        let isCancelling: Bool
    }

    private let persistenceCoordinator: PersistenceCoordinator
    private var runtimeSnapshotStore: SessionRuntimeSnapshotStore?
    private var refreshCoordinator: RuntimeRecoveryRefreshCoordinator?
    private var refreshRepository: SwiftDataRuntimeRecoveryRefreshRepository?
    private var refreshTask: Task<Void, Never>?
    private(set) var persistedRecoveryItems: [PersistedRecoveryItem] = []

    init(persistenceCoordinator: PersistenceCoordinator) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    convenience init() {
        self.init(persistenceCoordinator: .shared)
    }

    func bindRuntimeSnapshotStore(_ runtimeSnapshotStore: SessionRuntimeSnapshotStore) {
        self.runtimeSnapshotStore = runtimeSnapshotStore
    }

    func configurePersistence(container: ModelContainer) {
        let repository = SwiftDataRuntimeRecoveryRefreshRepository(
            container: container,
            persistenceCoordinator: persistenceCoordinator
        )
        refreshRepository = repository
        refreshCoordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)
    }

    func scheduleBootstrapRefresh() async {
        await scheduleRefresh(.bootstrap)
    }

    func scheduleRefresh(_ event: RuntimeRecoveryRefreshEvent) async {
        guard let refreshCoordinator else {
            return
        }

        await refreshCoordinator.enqueue(event)
        startRefreshLoopIfNeeded()
    }

    func waitForRefreshForTesting() async {
        await refreshTask?.value
    }

    func recoveryItems(for sessionId: String) -> [PersistedRecoveryItem] {
        persistedRecoveryItems.filter { $0.sessionID == sessionId }
    }

    func allPersistedRecoveryItems() -> [PersistedRecoveryItem] {
        persistedRecoveryItems
    }

    func runtimeRecoveryItem(for sessionId: String) -> RuntimeRecoveryItem? {
        guard let runtimeSnapshotStore else {
            return nil
        }

        return makeRuntimeRecoveryItem(from: runtimeSnapshotStore.snapshot(for: sessionId))
    }

    func runtimeRecoveryItems(for sessionId: String) -> [RuntimeRecoveryItem] {
        guard let item = runtimeRecoveryItem(for: sessionId) else {
            return []
        }
        return [item]
    }

    func allRuntimeRecoveryItems() -> [RuntimeRecoveryItem] {
        guard let runtimeSnapshotStore else {
            return []
        }

        return runtimeSnapshotStore.allSnapshots.compactMap(makeRuntimeRecoveryItem(from:))
    }

    func markViewed(_ item: PersistedRecoveryItem) async throws {
        try await refreshRepository?.update(
            itemID: item.id,
            terminalAction: nil,
            handlingState: .viewed
        )
        await scheduleRefresh(.snapshotActionCompleted(itemIDs: [item.id]))
    }

    func markInterrupted(_ item: PersistedRecoveryItem) async throws {
        try await refreshRepository?.update(
            itemID: item.id,
            terminalAction: .interrupted,
            handlingState: .interrupted
        )
        await scheduleRefresh(.snapshotActionCompleted(itemIDs: [item.id]))
    }

    func clear(_ item: PersistedRecoveryItem) async throws {
        try await refreshRepository?.update(
            itemID: item.id,
            terminalAction: .cleared,
            handlingState: .cleared
        )
        await scheduleRefresh(.snapshotActionCompleted(itemIDs: [item.id]))
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

    private func makeRuntimeRecoveryItem(from snapshot: SessionRuntimeSnapshot) -> RuntimeRecoveryItem? {
        guard snapshot.isRunning || snapshot.queuedJobIDs.isEmpty == false || snapshot.isCancelling else {
            return nil
        }

        let diagnostics = SessionRuntimeDiagnosticsSnapshot(snapshot: snapshot)
        let summaryText: String
        if snapshot.isCancelling {
            summaryText = "当前运行正在取消，队列中还有 \(snapshot.queuedJobIDs.count) 项待处理。"
        } else if snapshot.isRunning && snapshot.queuedJobIDs.isEmpty == false {
            summaryText = "当前有运行中的 \(diagnostics.providerText) 任务，另有 \(snapshot.queuedJobIDs.count) 项排队。"
        } else if snapshot.isRunning {
            summaryText = "当前仍有运行中的 \(diagnostics.providerText) 任务，需要等待收敛。"
        } else {
            summaryText = "当前仍有 \(snapshot.queuedJobIDs.count) 项排队任务等待恢复。"
        }

        return RuntimeRecoveryItem(
            id: snapshot.sessionID,
            sessionID: snapshot.sessionID,
            titleText: "会话运行态恢复",
            summaryText: summaryText,
            isCancelling: snapshot.isCancelling
        )
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshTask == nil, let refreshCoordinator else {
            return
        }

        refreshTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }

            while true {
                do {
                    let result = try await refreshCoordinator.flushForTesting()
                    self.persistedRecoveryItems = result.items
                } catch {
                    break
                }

                if await refreshCoordinator.hasPendingWork() == false {
                    break
                }
            }

            self.refreshTask = nil
        }
    }
}

extension RuntimeRecoveryService: RuntimeRecoveryRefreshSink {
    func enqueue(_ event: RuntimeRecoveryRefreshEvent) async {
        await scheduleRefresh(event)
    }
}

private actor SwiftDataRuntimeRecoveryRefreshRepository: RuntimeRecoveryRefreshRepository {
    enum TerminalAction {
        case interrupted
        case cleared
    }

    private let container: ModelContainer
    private let persistenceCoordinator: PersistenceCoordinator

    init(container: ModelContainer, persistenceCoordinator: PersistenceCoordinator) {
        self.container = container
        self.persistenceCoordinator = persistenceCoordinator
    }

    func fetchPendingSourcesAndVisibleSnapshots() async throws -> RuntimeRecoveryRefreshBootstrapState {
        let modelContext = ModelContext(container)
        let pendingMessageItems = try fetchPendingMessageItems(in: modelContext)
        let pendingBackgroundItems = try fetchPendingBackgroundTaskItems(in: modelContext)
        let visibleItems = try fetchVisibleRecoveryItems(in: modelContext)

        return RuntimeRecoveryRefreshBootstrapState(
            pendingMessageIDs: Set(pendingMessageItems.map(\.id)),
            pendingBackgroundTaskRunIDs: Set(pendingBackgroundItems.map(\.id)),
            visibleItems: visibleItems
        )
    }

    func fetchMessages(ids: Set<UUID>) async throws -> [PersistedRecoveryItem] {
        guard ids.isEmpty == false else {
            return []
        }

        let modelContext = ModelContext(container)
        let messages = try modelContext.fetch(FetchDescriptor<Message>())
        return messages
            .filter { ids.contains($0.id) }
            .compactMap(makePersistedRecoveryItem(from:))
            .sorted(by: itemSort)
    }

    func fetchBackgroundTaskRuns(ids: Set<UUID>) async throws -> [PersistedRecoveryItem] {
        guard ids.isEmpty == false else {
            return []
        }

        let modelContext = ModelContext(container)
        let taskLookup = try backgroundTaskLookup(in: modelContext)
        let runs = try modelContext.fetch(FetchDescriptor<BackgroundAgentTaskRun>())
        return runs
            .filter { ids.contains($0.id) }
            .compactMap { makePersistedRecoveryItem(from: $0, taskLookup: taskLookup) }
            .sorted(by: itemSort)
    }

    func reconcile(
        messageItems: [PersistedRecoveryItem],
        backgroundTaskItems: [PersistedRecoveryItem]
    ) async throws -> RuntimeRecoveryRefreshResult {
        let modelContext = ModelContext(container)
        let desiredItems = (messageItems + backgroundTaskItems).sorted(by: itemSort)
        let desiredItemsByKey = Dictionary(uniqueKeysWithValues: desiredItems.map {
            (snapshotKey(kind: $0.sourceKind, identifier: $0.sourceIdentifier), $0)
        })
        let snapshots = try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
        var changed = false
        var removedSourceKeys: Set<String> = []

        for snapshot in snapshots {
            let key = snapshotKey(kind: snapshot.sourceKind, identifier: snapshot.sourceIdentifier)
            if let desiredItem = desiredItemsByKey[key] {
                if snapshot.sessionId != desiredItem.sessionID {
                    snapshot.sessionId = desiredItem.sessionID
                    changed = true
                }
                if snapshot.summaryText != desiredItem.summaryText {
                    snapshot.summaryText = desiredItem.summaryText
                    changed = true
                }
                let metadata = metadata(for: desiredItem)
                let encodedMetadata = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
                if snapshot.metadataJSON != encodedMetadata {
                    snapshot.metadataJSON = encodedMetadata
                    changed = true
                }
                if snapshot.handlingState != desiredItem.handlingState {
                    snapshot.handlingState = desiredItem.handlingState
                    changed = true
                }
            } else if isVisible(snapshot.handlingStateRaw) {
                modelContext.delete(snapshot)
                removedSourceKeys.insert(key)
                changed = true
            }
        }

        let existingKeys = Set(snapshots.map { snapshotKey(kind: $0.sourceKind, identifier: $0.sourceIdentifier) })
        for item in desiredItems where existingKeys.contains(snapshotKey(kind: item.sourceKind, identifier: item.sourceIdentifier)) == false {
            let snapshot = RecoverySnapshot(
                id: item.id,
                sessionId: item.sessionID,
                sourceKind: item.sourceKind,
                sourceIdentifier: item.sourceIdentifier,
                summaryText: item.summaryText,
                metadata: metadata(for: item),
                handlingState: item.handlingState
            )
            modelContext.insert(snapshot)
            changed = true
        }

        if changed {
            try await MainActor.run {
                try persistenceCoordinator.save(
                    modelContext,
                    domain: .sessionTaskState,
                    userMessage: "恢复摘要同步未成功保存"
                )
            }
        }

        let visibleItems = try fetchVisibleRecoveryItems(in: modelContext)
        return RuntimeRecoveryRefreshResult(
            items: visibleItems,
            updatedItemIDs: Set(desiredItems.map(\.id)),
            removedSourceKeys: removedSourceKeys
        )
    }

    func update(
        itemID: UUID,
        terminalAction: TerminalAction?,
        handlingState: RecoveryHandlingState
    ) async throws {
        let modelContext = ModelContext(container)
        let snapshots = try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
        guard let snapshot = snapshots.first(where: { $0.id == itemID }) else {
            return
        }

        if let terminalAction {
            try normalizeSource(snapshot, in: modelContext, terminalAction: terminalAction)
        }
        snapshot.handlingState = handlingState
        try await MainActor.run {
            try persistenceCoordinator.save(
                modelContext,
                domain: .sessionTaskState,
                userMessage: "恢复状态未成功保存"
            )
        }
    }

    private func fetchPendingMessageItems(in modelContext: ModelContext) throws -> [PersistedRecoveryItem] {
        try modelContext.fetch(FetchDescriptor<Message>())
            .compactMap(makePersistedRecoveryItem(from:))
            .sorted(by: itemSort)
    }

    private func fetchPendingBackgroundTaskItems(in modelContext: ModelContext) throws -> [PersistedRecoveryItem] {
        let taskLookup = try backgroundTaskLookup(in: modelContext)
        return try modelContext.fetch(FetchDescriptor<BackgroundAgentTaskRun>())
            .compactMap { makePersistedRecoveryItem(from: $0, taskLookup: taskLookup) }
            .sorted(by: itemSort)
    }

    private func fetchVisibleRecoveryItems(in modelContext: ModelContext) throws -> [PersistedRecoveryItem] {
        try modelContext.fetch(FetchDescriptor<RecoverySnapshot>())
            .filter { isVisible($0.handlingStateRaw) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(makePersistedRecoveryItem(from:))
    }

    private func backgroundTaskLookup(in modelContext: ModelContext) throws -> [UUID: BackgroundAgentTask] {
        Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<BackgroundAgentTask>()).map { ($0.id, $0) })
    }

    private func makePersistedRecoveryItem(from message: Message) -> PersistedRecoveryItem? {
        guard message.direction == .agent,
              message.status == .pending,
              let sessionID = message.session?.sessionId else {
            return nil
        }

        let summaryText = message.textContent?.isEmpty == false
            ? "未完成的回复：\(String((message.textContent ?? "").prefix(80)))"
            : "上一轮回复在生成过程中被中断"

        return PersistedRecoveryItem(
            id: message.id,
            sessionID: sessionID,
            sourceKind: .messageGeneration,
            sourceIdentifier: message.id.uuidString,
            titleText: "检测到可恢复的消息生成",
            summaryText: summaryText,
            handlingState: .pending
        )
    }

    private func makePersistedRecoveryItem(
        from run: BackgroundAgentTaskRun,
        taskLookup: [UUID: BackgroundAgentTask]
    ) -> PersistedRecoveryItem? {
        guard run.status == .triggered || run.status == .running,
              let task = taskLookup[run.taskID] else {
            return nil
        }

        let summaryText: String
        switch run.status {
        case .triggered:
            summaryText = "后台任务已触发，等待恢复执行。"
        case .running:
            summaryText = "后台任务仍在运行，等待恢复收敛。"
        default:
            return nil
        }

        return PersistedRecoveryItem(
            id: run.id,
            sessionID: task.sessionId,
            sourceKind: .bashTask,
            sourceIdentifier: run.id.uuidString,
            titleText: "检测到可恢复的 Bash 任务",
            summaryText: summaryText,
            handlingState: .pending
        )
    }

    private func makePersistedRecoveryItem(from snapshot: RecoverySnapshot) -> PersistedRecoveryItem {
        PersistedRecoveryItem(
            id: snapshot.id,
            sessionID: snapshot.sessionId,
            sourceKind: snapshot.sourceKind,
            sourceIdentifier: snapshot.sourceIdentifier,
            titleText: recoveryTitleText(for: snapshot.sourceKindRaw),
            summaryText: snapshot.summaryText,
            handlingState: snapshot.handlingState
        )
    }

    private func metadata(for item: PersistedRecoveryItem) -> [String: String] {
        switch item.sourceKind {
        case .messageGeneration:
            return ["messageId": item.sourceIdentifier]
        case .bashTask:
            return ["runId": item.sourceIdentifier]
        }
    }

    private func normalizeSource(
        _ snapshot: RecoverySnapshot,
        in modelContext: ModelContext,
        terminalAction: TerminalAction
    ) throws {
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

    private func snapshotKey(kind: RecoverySourceKind, identifier: String) -> String {
        "\(kind.rawValue):\(identifier)"
    }

    private func isVisible(_ handlingStateRaw: String) -> Bool {
        switch handlingStateRaw {
        case RecoveryHandlingState.pending.rawValue, RecoveryHandlingState.viewed.rawValue:
            return true
        default:
            return false
        }
    }

    private func recoveryTitleText(for sourceKindRaw: String) -> String {
        switch RecoverySourceKind(rawValue: sourceKindRaw) ?? .messageGeneration {
        case .messageGeneration:
            return "检测到可恢复的消息生成"
        case .bashTask:
            return "检测到可恢复的Bash 任务"
        }
    }

    private func itemSort(lhs: PersistedRecoveryItem, rhs: PersistedRecoveryItem) -> Bool {
        if lhs.sessionID == rhs.sessionID {
            return lhs.sourceIdentifier < rhs.sourceIdentifier
        }
        return lhs.sessionID < rhs.sessionID
    }
}