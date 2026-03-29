import Foundation

@MainActor
protocol RuntimeRecoveryRefreshSink: AnyObject, Sendable {
    func enqueue(_ event: RuntimeRecoveryRefreshEvent) async
}

enum RuntimeRecoveryRefreshEvent: Equatable, Sendable {
    case bootstrap
    case messageChanged(messageIDs: [UUID])
    case backgroundTaskChanged(runIDs: [UUID])
    case snapshotActionCompleted(itemIDs: [UUID])
}

struct RuntimeRecoveryRefreshBootstrapState: Sendable {
    let pendingMessageIDs: Set<UUID>
    let pendingBackgroundTaskRunIDs: Set<UUID>
    let visibleItems: [PersistedRecoveryItem]
}

struct RuntimeRecoveryRefreshResult: Sendable {
    let items: [PersistedRecoveryItem]
    let updatedItemIDs: Set<UUID>
    let removedSourceKeys: Set<String>
}

protocol RuntimeRecoveryRefreshRepository: Sendable {
    func fetchPendingSourcesAndVisibleSnapshots() async throws -> RuntimeRecoveryRefreshBootstrapState
    func fetchMessages(ids: Set<UUID>) async throws -> [PersistedRecoveryItem]
    func fetchBackgroundTaskRuns(ids: Set<UUID>) async throws -> [PersistedRecoveryItem]
    func reconcile(
        messageItems: [PersistedRecoveryItem],
        backgroundTaskItems: [PersistedRecoveryItem]
    ) async throws -> RuntimeRecoveryRefreshResult
}