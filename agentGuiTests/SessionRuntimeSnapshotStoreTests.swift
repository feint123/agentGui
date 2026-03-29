import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionRuntimeSnapshotStoreTests {
    @Test
    func applyStartEventPublishesRunningSnapshot() {
        let store = SessionRuntimeSnapshotStore()
        let jobID = UUID()

        store.apply(
            .started(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        let snapshot = store.snapshot(for: "session-a")
        #expect(snapshot.runningJobID == jobID)
        #expect(snapshot.runningProviderReference == .builtIn)
        #expect(snapshot.isRunning)
    }

    @Test
    func busPublishesSnapshotAfterCancelRequest() {
        let store = SessionRuntimeSnapshotStore()
        let bus = SessionRuntimeBus(store: store)
        let jobID = UUID()

        bus.publish(.started(sessionID: "session-a", jobID: jobID, providerReference: .builtIn))
        bus.publish(.cancelRequested(sessionID: "session-a", jobID: jobID))

        let snapshot = store.snapshot(for: "session-a")
        #expect(snapshot.isRunning)
        #expect(snapshot.isCancelling)
        #expect(snapshot.requestedCancellationJobIDs == [jobID])
    }
}