import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionControllerTests {
    @Test
    func controllerDoesNotSeedProjectionStoreOnInitialization() {
        let store = ExecutionProjectionStore()

        _ = SessionExecutionController(sessionID: "session-a", projectionStore: store)

        #expect(store.projections.isEmpty)
    }

    @Test
    func controllerReflectsStoreProjectionWithoutWriteBack() {
        let store = ExecutionProjectionStore()
        store.apply(.enqueued(
            sessionID: "session-a",
            jobID: UUID(),
            providerReference: .builtIn
        ))

        let controller = SessionExecutionController(sessionID: "session-a", projectionStore: store)

        #expect(controller.projection.activityState == .queued)
        #expect(controller.projection.queuedCount == 1)
    }

    @Test
    func syncFromStoreRefreshesControllerProjection() {
        let store = ExecutionProjectionStore()
        let controller = SessionExecutionController(sessionID: "session-a", projectionStore: store)

        store.apply(.enqueued(
            sessionID: "session-a",
            jobID: UUID(),
            providerReference: .builtIn
        ))
        controller.syncFromStore()

        #expect(controller.projection.activityState == .queued)
        #expect(controller.projection.activeProviderReference == .builtIn)
    }
}