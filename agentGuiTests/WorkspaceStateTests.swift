import Foundation
import Observation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceStateTests {
    @Test
    func selectingSessionPublishesForegroundPresentationWithoutRegistry() {
        let projectionStore = ExecutionProjectionStore()
        let workspaceState = WorkspaceState()
        workspaceState.bindExecutionProjectionStore(projectionStore)

        let first = Session.fixture(sessionId: "session-a", title: "A")
        let second = Session.fixture(sessionId: "session-b", title: "B")

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

        workspaceState.selectedSession = first
        workspaceState.selectedSession = second

        #expect(projectionStore.projection(for: first.sessionId).presentationState == .background)
        #expect(projectionStore.projection(for: second.sessionId).presentationState == .foreground)
    }

    @Test
    func executionProjectionAccessInvalidatesWhenStoreChanges() {
        let projectionStore = ExecutionProjectionStore()
        let workspaceState = WorkspaceState()
        workspaceState.bindExecutionProjectionStore(projectionStore)

        var invalidationCount = 0
        withObservationTracking {
            _ = workspaceState.executionProjection(for: "session-observed")
        } onChange: {
            invalidationCount += 1
        }

        projectionStore.apply(.presentationChanged(sessionID: "session-observed", state: .background))

        #expect(invalidationCount == 1)
    }

    @Test
    func bindingProjectionStoreSeedsForegroundSelectionFromCurrentSession() {
        let projectionStore = ExecutionProjectionStore()
        let workspaceState = WorkspaceState()
        let selectedSession = Session.fixture(sessionId: "session-selected", title: "Selected")
        workspaceState.selectedSession = selectedSession

        projectionStore.apply(.started(
            sessionID: selectedSession.sessionId,
            jobID: UUID(),
            providerReference: .builtIn
        ))

        workspaceState.bindExecutionProjectionStore(projectionStore)

        #expect(workspaceState.executionProjection(for: selectedSession.sessionId).presentationState == .foreground)
    }

    @Test
    func unboundProjectionAccessFallsBackToEmptyProjection() {
        let workspaceState = WorkspaceState()

        let projection = workspaceState.executionProjection(for: "session-a")

        #expect(projection == .empty(sessionID: "session-a"))
    }
}