import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionRuntimeBusTests {
    @Test
    func busPublishesRunningRuntimeSnapshot() {
        let store = SessionRuntimeSnapshotStore()
        let bus = SessionRuntimeBus(store: store)
        let jobID = UUID()

        bus.publish(
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
    func fanoutWriterUpdatesProjectionAndRuntimeSnapshotsTogether() {
        let projectionStore = ExecutionProjectionStore()
        let runtimeSnapshotStore = SessionRuntimeSnapshotStore()
        let runtimeBus = SessionRuntimeBus(store: runtimeSnapshotStore)
        let writer = SessionExecutionLifecycleFanoutWriter(
            projectionWriter: projectionStore,
            runtimeBus: runtimeBus
        )

        writer.apply(
            .started(
                sessionID: "session-a",
                jobID: UUID(),
                providerReference: .builtIn
            )
        )

        #expect(projectionStore.projection(for: "session-a").isRunning)
        #expect(runtimeSnapshotStore.snapshot(for: "session-a").isRunning)
    }
}