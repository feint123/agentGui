import Foundation
import Testing
@testable import agentGui

struct RuntimeRecoveryRefreshCoordinatorTests {
    @Test
    func bootstrapRefreshOnlyFetchesPendingSourcesAndVisibleSnapshots() async throws {
        let repository = RecoveryRefreshRepositorySpy()
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)

        await coordinator.enqueue(.bootstrap)
        let result = try await coordinator.flushForTesting()

        #expect(repository.bootstrapFetchCount == 1)
        #expect(repository.messageFetchCalls.isEmpty)
        #expect(repository.backgroundTaskFetchCalls.isEmpty)
        #expect(result.updatedItemIDs == Set(repository.persistedItems.map(\.id)))
    }

    @Test
    func incrementalMessageEventOnlyReconcilesAffectedMessageIDs() async throws {
        let repository = RecoveryRefreshRepositorySpy()
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)
        let messageID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        await coordinator.enqueue(.messageChanged(messageIDs: [messageID]))
        let result = try await coordinator.flushForTesting()

        #expect(repository.messageFetchCalls == [.specificIDs([messageID])])
        #expect(result.updatedItemIDs == [messageID])
    }

    @Test
    func multipleQueuedEventsAreMergedIntoSingleBatch() async throws {
        let repository = RecoveryRefreshRepositorySpy()
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)
        let messageID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let runID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

        await coordinator.enqueue(.messageChanged(messageIDs: [messageID]))
        await coordinator.enqueue(.messageChanged(messageIDs: [messageID]))
        await coordinator.enqueue(.backgroundTaskChanged(runIDs: [runID]))

        _ = try await coordinator.flushForTesting()

        #expect(repository.messageFetchCalls == [.specificIDs([messageID])])
        #expect(repository.backgroundTaskFetchCalls == [.specificIDs([runID])])
        #expect(repository.reconcileCallCount == 1)
    }

    @Test
    func bootstrapReconcileDoesNotFetchAllMessagesWhenOnlyThreePendingRemain() async throws {
        let messageIDs = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        ]
        let repository = RecoveryRefreshRepositorySpy(
            bootstrapState: RuntimeRecoveryRefreshBootstrapState(
                pendingMessageIDs: Set(messageIDs),
                pendingBackgroundTaskRunIDs: [],
                visibleItems: []
            )
        )
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)

        await coordinator.enqueue(.bootstrap)
        _ = try await coordinator.flushForTesting()

        #expect(repository.messageFetchCalls == [.specificIDs(messageIDs)])
        #expect(repository.backgroundTaskFetchCalls.isEmpty)
    }

    @Test
    func burstOfFiftyEventsProducesBoundedNumberOfSaveOperations() async throws {
        let repository = RecoveryRefreshRepositorySpy()
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)

        for index in 0..<50 {
            let messageID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            await coordinator.enqueue(.messageChanged(messageIDs: [messageID]))
        }

        _ = try await coordinator.flushForTesting()

        #expect(repository.reconcileCallCount == 1)
        #expect(repository.saveCallCount <= 3)
    }

    @Test
    func largeHistoryWithSmallPendingSetRefreshesAgainstPendingCardinality() async throws {
        let pendingMessageIDs = [
            UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        ]
        let repository = RecoveryRefreshRepositorySpy(
            bootstrapState: RuntimeRecoveryRefreshBootstrapState(
                pendingMessageIDs: Set(pendingMessageIDs),
                pendingBackgroundTaskRunIDs: [],
                visibleItems: []
            ),
            historyMessageCount: 10_000
        )
        let coordinator = RuntimeRecoveryRefreshCoordinator(repository: repository)

        await coordinator.enqueue(.bootstrap)
        _ = try await coordinator.flushForTesting()

        #expect(repository.totalFetchedMessageCount == 3)
        #expect(repository.fullMessageScanCount == 0)
    }
}

private final class RecoveryRefreshRepositorySpy: RuntimeRecoveryRefreshRepository {
    enum IDFetchCall: Equatable {
        case specificIDs([UUID])
    }

    var bootstrapFetchCount = 0
    var messageFetchCalls: [IDFetchCall] = []
    var backgroundTaskFetchCalls: [IDFetchCall] = []
    var reconcileCallCount = 0
    var saveCallCount = 0
    let historyMessageCount: Int
    var totalFetchedMessageCount = 0
    var fullMessageScanCount = 0

    let bootstrapState: RuntimeRecoveryRefreshBootstrapState

    init(
        bootstrapState: RuntimeRecoveryRefreshBootstrapState = RuntimeRecoveryRefreshBootstrapState(
            pendingMessageIDs: [],
            pendingBackgroundTaskRunIDs: [],
            visibleItems: [
                PersistedRecoveryItem(
                    id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                    sessionID: "session-a",
                    sourceKind: .messageGeneration,
                    sourceIdentifier: "message-a",
                    titleText: "检测到可恢复的消息生成",
                    summaryText: "未完成的回复",
                    handlingState: .pending
                )
            ]
        ),
        historyMessageCount: Int = 0
    ) {
        self.bootstrapState = bootstrapState
        self.historyMessageCount = historyMessageCount
    }

    var persistedItems: [PersistedRecoveryItem] {
        bootstrapState.visibleItems
    }

    func fetchPendingSourcesAndVisibleSnapshots() async throws -> RuntimeRecoveryRefreshBootstrapState {
        bootstrapFetchCount += 1
        return bootstrapState
    }

    func fetchMessages(ids: Set<UUID>) async throws -> [PersistedRecoveryItem] {
        messageFetchCalls.append(.specificIDs(ids.sorted { $0.uuidString < $1.uuidString }))
        totalFetchedMessageCount += ids.count
        if ids.count >= historyMessageCount, historyMessageCount > 0 {
            fullMessageScanCount += 1
        }
        return ids.map {
            PersistedRecoveryItem(
                id: $0,
                sessionID: "session-a",
                sourceKind: .messageGeneration,
                sourceIdentifier: $0.uuidString,
                titleText: "检测到可恢复的消息生成",
                summaryText: "未完成的回复",
                handlingState: .pending
            )
        }
    }

    func fetchBackgroundTaskRuns(ids: Set<UUID>) async throws -> [PersistedRecoveryItem] {
        backgroundTaskFetchCalls.append(.specificIDs(ids.sorted { $0.uuidString < $1.uuidString }))
        return ids.map {
            PersistedRecoveryItem(
                id: $0,
                sessionID: "session-a",
                sourceKind: .bashTask,
                sourceIdentifier: $0.uuidString,
                titleText: "检测到可恢复的 Bash 任务",
                summaryText: "任务仍未完成",
                handlingState: .pending
            )
        }
    }

    func reconcile(messageItems: [PersistedRecoveryItem], backgroundTaskItems: [PersistedRecoveryItem]) async throws -> RuntimeRecoveryRefreshResult {
        reconcileCallCount += 1
        saveCallCount += 1
        let items = persistedItems + messageItems + backgroundTaskItems
        return RuntimeRecoveryRefreshResult(
            items: items,
            updatedItemIDs: Set(items.map(\.id)),
            removedSourceKeys: []
        )
    }
}