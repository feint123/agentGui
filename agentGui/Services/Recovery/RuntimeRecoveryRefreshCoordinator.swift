import Foundation

actor RuntimeRecoveryRefreshCoordinator {
    private let repository: RuntimeRecoveryRefreshRepository
    private var bootstrapRequested = false
    private var dirtyMessageIDs: Set<UUID> = []
    private var dirtyBackgroundTaskRunIDs: Set<UUID> = []

    init(repository: RuntimeRecoveryRefreshRepository) {
        self.repository = repository
    }

    func enqueue(_ event: RuntimeRecoveryRefreshEvent) {
        switch event {
        case .bootstrap:
            bootstrapRequested = true
        case let .messageChanged(messageIDs):
            dirtyMessageIDs.formUnion(messageIDs)
        case let .backgroundTaskChanged(runIDs):
            dirtyBackgroundTaskRunIDs.formUnion(runIDs)
        case let .snapshotActionCompleted(itemIDs):
            dirtyMessageIDs.formUnion(itemIDs)
            dirtyBackgroundTaskRunIDs.formUnion(itemIDs)
        }
    }

    func flushForTesting() async throws -> RuntimeRecoveryRefreshResult {
        let shouldBootstrap = bootstrapRequested
        let messageIDs = dirtyMessageIDs
        let backgroundTaskRunIDs = dirtyBackgroundTaskRunIDs

        bootstrapRequested = false
        dirtyMessageIDs = []
        dirtyBackgroundTaskRunIDs = []

        let bootstrapState = shouldBootstrap
            ? try await repository.fetchPendingSourcesAndVisibleSnapshots()
            : RuntimeRecoveryRefreshBootstrapState(
                pendingMessageIDs: [],
                pendingBackgroundTaskRunIDs: [],
                visibleItems: []
            )

        let requestedMessageIDs = messageIDs.union(bootstrapState.pendingMessageIDs)
        let requestedBackgroundTaskRunIDs = backgroundTaskRunIDs.union(bootstrapState.pendingBackgroundTaskRunIDs)
        let messageItems = requestedMessageIDs.isEmpty
            ? []
            : try await repository.fetchMessages(ids: requestedMessageIDs)
        let backgroundTaskItems = requestedBackgroundTaskRunIDs.isEmpty
            ? []
            : try await repository.fetchBackgroundTaskRuns(ids: requestedBackgroundTaskRunIDs)
        var result = try await repository.reconcile(
            messageItems: messageItems,
            backgroundTaskItems: backgroundTaskItems
        )

        let updatedIDs = Set(messageItems.map(\.id)).union(backgroundTaskItems.map(\.id))
        if shouldBootstrap {
            let visibleIDs = bootstrapState.visibleItems.map(\.id)
            result = RuntimeRecoveryRefreshResult(
                items: result.items,
                updatedItemIDs: updatedIDs.union(visibleIDs),
                removedSourceKeys: result.removedSourceKeys
            )
        } else {
            result = RuntimeRecoveryRefreshResult(
                items: result.items,
                updatedItemIDs: updatedIDs,
                removedSourceKeys: result.removedSourceKeys
            )
        }

        return result
    }

    func hasPendingWork() -> Bool {
        bootstrapRequested || !dirtyMessageIDs.isEmpty || !dirtyBackgroundTaskRunIDs.isEmpty
    }
}