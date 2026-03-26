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
        let projection = SessionExecutionProjection(
            sessionID: "session-a",
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

        store.setProjection(projection)

        #expect(store.projection(for: "session-a") == projection)
    }
}