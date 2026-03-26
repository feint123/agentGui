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
    func selectingForegroundSessionBackgroundsSiblings() {
        let registry = SessionExecutionRegistry()
        let first = registry.controller(for: "session-a")
        let second = registry.controller(for: "session-b")

        first.recordRunning(jobID: nil, providerID: .builtInAgent, currentPhase: .executing)
        second.recordRunning(jobID: nil, providerID: .builtInAgent, currentPhase: .executing)

        registry.setForegroundSession("session-b")

        #expect(first.projection.presentationState == .background)
        #expect(second.projection.presentationState == .foreground)
    }

    @Test
    func projectionReflectsExternalStoreUpdatesForExistingController() {
        let store = ExecutionProjectionStore()
        let registry = SessionExecutionRegistry(projectionStore: store)

        _ = registry.controller(for: "session-a")

        let updatedProjection = SessionExecutionProjection(
            sessionID: "session-a",
            runningJobID: UUID(),
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: true,
            canEditComposer: false,
            canSubmitNewJob: false,
            activeProviderID: .builtInAgent,
            currentPhase: .executing,
            activityState: .running,
            presentationState: .background,
            needsAttention: false,
            attentionReason: nil
        )

        store.setProjection(updatedProjection)

        #expect(registry.projection(for: "session-a") == updatedProjection)
    }
}