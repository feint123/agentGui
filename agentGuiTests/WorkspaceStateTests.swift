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

        workspaceState.executionRegistry.controller(for: first.sessionId)
            .recordRunning(jobID: UUID(), providerID: .builtInAgent, currentPhase: .executing)
        workspaceState.executionRegistry.controller(for: second.sessionId)
            .recordRunning(jobID: UUID(), providerID: .builtInAgent, currentPhase: .executing)

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
            SessionExecutionProjection(
                sessionID: session.sessionId,
                runningJobID: nil,
                queuedJobIDs: [],
                queuedCount: 0,
                isRunning: false,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .builtInAgent,
                currentPhase: nil,
                activityState: .blocked,
                presentationState: .background,
                needsAttention: true,
                attentionReason: .userQuestion
            )
        )

        #expect(invalidationCount == 1)
    }
}