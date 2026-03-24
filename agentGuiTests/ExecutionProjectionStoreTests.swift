import Foundation
import Testing
@testable import agentGui

@MainActor
struct ExecutionProjectionStoreTests {
    @Test func projectionStoreReturnsEmptyProjectionForUnknownSession() {
        let store = ExecutionProjectionStore()

        let projection = store.projection(for: "session-1")

        #expect(projection.sessionID == "session-1")
        #expect(projection.currentPhase == nil)
        #expect(projection.queuedJobIDs.isEmpty)
        #expect(projection.queuedCount == 0)
        #expect(projection.isRunning == false)
        #expect(projection.canEditComposer == true)
        #expect(projection.canSubmitNewJob == true)
    }

    @Test func projectionStorePersistsLatestProjectionBySession() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()
        store.setProjection(
            SessionExecutionProjection(
                sessionID: "session-1",
                runningJobID: nil,
                queuedJobIDs: [jobID],
                queuedCount: 1,
                isRunning: false,
                canEditComposer: true,
                canSubmitNewJob: true,
                activeProviderID: .githubCopilotCLI,
                currentPhase: nil
            )
        )

        let projection = store.projection(for: "session-1")

        #expect(projection.queuedJobIDs == [jobID])
        #expect(projection.activeProviderID == .githubCopilotCLI)
        #expect(projection.currentPhase == nil)
    }
}