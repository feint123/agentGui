import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionRuntimeStateStoreTests {
    @Test
    func applyStartEventPublishesRunningRuntimeSnapshot() {
        let store = SessionExecutionRuntimeStateStore()
        let jobID = UUID()

        store.apply(
            .started(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        let snapshot = store.state(for: "session-a")
        #expect(snapshot.runningJobID == jobID)
        #expect(snapshot.runningProviderReference == .builtIn)
        #expect(snapshot.isRunning)
    }

    @Test
    func fanoutWriterUpdatesProjectionAndRuntimeStoresTogether() {
        let projectionStore = ExecutionProjectionStore()
        let runtimeStore = SessionExecutionRuntimeStateStore()
        let writer = SessionExecutionLifecycleFanoutWriter(
            projectionWriter: projectionStore,
            runtimeStateWriter: runtimeStore
        )

        writer.apply(
            .started(
                sessionID: "session-a",
                jobID: UUID(),
                providerReference: .builtIn
            )
        )

        #expect(projectionStore.projection(for: "session-a").isRunning)
        #expect(runtimeStore.state(for: "session-a").isRunning)
    }
}