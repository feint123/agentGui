import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RuntimeRecoveryServiceRuntimeSnapshotTests {
    @Test
    func runtimeRecoverySummaryUsesSnapshotForQueuedAndRunningSessions() {
        let store = SessionRuntimeSnapshotStore()
        let service = RuntimeRecoveryService()
        service.bindRuntimeSnapshotStore(store)
        let runningJobID = UUID()

        store.apply(
            .recovered(
                sessionID: "session-a",
                queuedJobIDs: [UUID(), runningJobID],
                runningJobID: runningJobID,
                providerReference: .builtIn
            )
        )

        let items = service.runtimeRecoveryItems(for: "session-a")
        #expect(items.isEmpty == false)
        #expect(items.first?.sessionID == "session-a")
        #expect(items.first?.summaryText.localizedStandardContains("排队") == true)
    }

    @Test
    func runtimeRecoverySummaryMarksCancellingSessions() {
        let store = SessionRuntimeSnapshotStore()
        let service = RuntimeRecoveryService()
        service.bindRuntimeSnapshotStore(store)
        let runningJobID = UUID()

        store.apply(.started(sessionID: "session-a", jobID: runningJobID, providerReference: .builtIn))
        store.apply(.cancelRequested(sessionID: "session-a", jobID: runningJobID))

        let item = service.runtimeRecoveryItems(for: "session-a").first
        #expect(item?.isCancelling == true)
        #expect(item?.summaryText.localizedStandardContains("取消") == true)
    }

    @Test
    func runtimeRecoverySummaryDoesNotReadPersistedRecoverySnapshots() async throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let service = RuntimeRecoveryService()
        service.configurePersistence(container: container)

        let session = Session.fixture(sessionId: "session-a", title: "Recovery")
        let pendingMessage = Message.agentFixture(
            text: "Partial response that should be recovered",
            session: session,
            status: .pending
        )
        let snapshot = RecoverySnapshot(
            sessionId: session.sessionId,
            sourceKind: .messageGeneration,
            sourceIdentifier: pendingMessage.id.uuidString,
            summaryText: "未完成的回复"
        )
        context.insert(session)
        context.insert(pendingMessage)
        context.insert(snapshot)
        try context.save()

        await service.scheduleBootstrapRefresh()
        await service.waitForRefreshForTesting()

        #expect(service.recoveryItems(for: session.sessionId).count == 1)
        #expect(service.runtimeRecoveryItem(for: session.sessionId) == nil)
    }
}