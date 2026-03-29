import Foundation
import Observation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceStateTests {
    @Test
    func selectingSessionMarksSiblingProjectionAsBackground() {
        let projectionStore = ExecutionProjectionStore()
        let workspaceState = WorkspaceState()
        workspaceState.executionRegistry = SessionExecutionRegistry(projectionStore: projectionStore)

        let first = Session()
        let second = Session()

        projectionStore.apply(.started(
            sessionID: first.sessionId,
            jobID: UUID(),
            providerReference: .builtIn
        ))
        projectionStore.apply(.started(
            sessionID: second.sessionId,
            jobID: UUID(),
            providerReference: .builtIn
        ))

        _ = workspaceState.executionRegistry.controller(for: first.sessionId)
        _ = workspaceState.executionRegistry.controller(for: second.sessionId)

        workspaceState.selectedSession = first
        workspaceState.selectedSession = second

        #expect(projectionStore.projection(for: first.sessionId).presentationState == .background)
        #expect(projectionStore.projection(for: second.sessionId).presentationState == .foreground)
    }

    @Test
    func executionRegistryProjectionAccessInvalidatesWhenStoreChanges() {
        let projectionStore = ExecutionProjectionStore()
        let workspaceState = WorkspaceState()
        workspaceState.executionRegistry = SessionExecutionRegistry(projectionStore: projectionStore)

        let session = Session.fixture(sessionId: "session-observed", title: "Observed")
        _ = workspaceState.executionRegistry.controller(for: session.sessionId)

        var invalidationCount = 0
        withObservationTracking {
            _ = workspaceState.executionRegistry.projection(for: session.sessionId)
        } onChange: {
            invalidationCount += 1
        }

        projectionStore.setProjection(
            .fixture(
                sessionID: session.sessionId,
                activeProviderID: .builtInAgent,
                activityState: .blocked,
                presentationState: .background,
                needsAttention: true,
                attentionReason: .userQuestion
            )
        )

        #expect(invalidationCount == 1)
    }
}