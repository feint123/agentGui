import Foundation
import Testing
@testable import agentGui

@MainActor
struct ExecutionProjectionStoreTests {
    @Test
    func projectionDefaultsToIdleForegroundWithoutAttention() {
        let store = ExecutionProjectionStore()

        let projection = store.projection(for: "session-a")

        #expect(projection.sessionID == "session-a")
        #expect(projection.activityState == .idle)
        #expect(projection.presentationState == .foreground)
        #expect(projection.needsAttention == false)
        #expect(projection.attentionReason == nil)
    }

    @Test
    func setProjectionPersistsAttentionAndPresentationFields() {
        let store = ExecutionProjectionStore()
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            activeProviderID: .builtInAgent,
            activityState: .blocked,
            presentationState: .background,
            needsAttention: true,
            attentionReason: .userQuestion
        )

        store.setProjection(projection)

        #expect(store.projection(for: "session-a") == projection)
    }

    @Test
    func applyEventReducesFromCurrentProjection() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()

        store.apply(.enqueued(
            sessionID: "session-a",
            jobID: jobID,
            providerReference: .builtIn
        ))

        let projection = store.projection(for: "session-a")
        #expect(projection.queuedJobIDs == [jobID])
        #expect(projection.queuedCount == 1)
        #expect(projection.activityState == .queued)
        #expect(projection.activeProviderReference == .builtIn)
    }
}