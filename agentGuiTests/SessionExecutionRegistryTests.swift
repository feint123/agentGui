import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionRegistryTests {
    @Test
    func controllerLookupReusesSameControllerPerSession() {
        let registry = SessionExecutionRegistry()

        let first = registry.controller(for: "session-a")
        let second = registry.controller(for: "session-a")

        #expect(first === second)
    }

    @Test
    func controllerLookupDoesNotSeedEmptyProjectionIntoStore() {
        let store = ExecutionProjectionStore()
        let registry = SessionExecutionRegistry(projectionStore: store)

        _ = registry.controller(for: "session-a")

        #expect(store.projections.isEmpty)
    }

    @Test
    func selectingForegroundSessionUpdatesStorePresentationState() {
        let store = ExecutionProjectionStore()
        let registry = SessionExecutionRegistry(projectionStore: store)

        store.apply(.started(
            sessionID: "session-a",
            jobID: UUID(),
            providerReference: .builtIn
        ))
        store.apply(.started(
            sessionID: "session-b",
            jobID: UUID(),
            providerReference: .builtIn
        ))

        _ = registry.controller(for: "session-a")
        _ = registry.controller(for: "session-b")

        registry.setForegroundSession("session-b")

        #expect(store.projection(for: "session-a").presentationState == .background)
        #expect(store.projection(for: "session-b").presentationState == .foreground)
    }

    @Test
    func projectionReflectsExternalStoreUpdatesForExistingController() {
        let store = ExecutionProjectionStore()
        let registry = SessionExecutionRegistry(projectionStore: store)

        _ = registry.controller(for: "session-a")

        let updatedProjection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            runningJobID: UUID(),
            canEditComposer: false,
            canSubmitNewJob: false,
            activeProviderID: .builtInAgent,
            currentPhase: .executing,
            activityState: .running,
            presentationState: .background
        )

        store.setProjection(updatedProjection)

        #expect(registry.projection(for: "session-a") == updatedProjection)
    }
}