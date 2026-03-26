import Testing
@testable import agentGui

@MainActor
struct ACPExternalExecutionProviderBaseTests {
    @Test
    func releasePreparedRuntimeClosesSessionRuntimeWithoutRemovingBinding() async throws {
        let resetTracker = SessionRuntimeResetTracker()
        let provider = UnavailableACPTestExecutionProvider(sessionRuntimeResetter: { sessionID in
            await MainActor.run {
                resetTracker.record(sessionID)
            }
        })
        let supervisor = try #require(MultiSessionExecutionFixtureFactory.extractRuntimeSupervisor(from: provider))
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()

        _ = await supervisor.activation(for: harness.firstSession.sessionId)

        await provider.releasePreparedRuntime(
            localSessionID: harness.firstSession.sessionId,
            modelContext: harness.context,
            reason: .sessionBecameInactive
        )

        let activeSessionIDs = await supervisor.activeLocalSessionIDs()
        #expect(activeSessionIDs.isEmpty)
        #expect(resetTracker.resetSessionIDs == [harness.firstSession.sessionId])
    }

    @Test
    func sessionStateBatchesProjectedPersistenceUntilThreshold() {
        let state = ACPExternalProviderSessionStateStore.SessionState(localSessionID: "batch-test")

        for _ in 0..<(ACPExternalProviderSessionStateStore.SessionState.projectedPersistenceBatchThreshold - 1) {
            #expect(state.recordProjectedMutation() == false)
        }

        #expect(state.hasPendingProjectedMutations)
        #expect(
            state.pendingProjectedMutationCount
                == ACPExternalProviderSessionStateStore.SessionState.projectedPersistenceBatchThreshold - 1
        )
        #expect(state.recordProjectedMutation())

        state.resetProjectedMutations()

        #expect(state.hasPendingProjectedMutations == false)
        #expect(state.pendingProjectedMutationCount == 0)
    }

    @Test
    func clearRuntimeStateResetsProjectedPersistenceBatch() {
        let state = ACPExternalProviderSessionStateStore.SessionState(localSessionID: "batch-reset")

        _ = state.recordProjectedMutation(count: 3)
        #expect(state.pendingProjectedMutationCount == 3)

        state.clearRuntimeState(removeBinding: false, removeFeatureStore: false)

        #expect(state.pendingProjectedMutationCount == 0)
        #expect(state.hasPendingProjectedMutations == false)
    }
}