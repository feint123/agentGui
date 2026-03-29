import Foundation
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
}