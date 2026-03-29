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
    func projectionLookupDoesNotSeedEmptyProjectionIntoStore() {
        let store = ExecutionProjectionStore()

        _ = store.projection(for: "session-a")

        #expect(store.projections.isEmpty)
    }

    @Test
    func runtimeLifecycleEventsDoNotMutateProjectionWithoutSnapshot() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()

        store.apply(
            .started(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        #expect(store.projections.isEmpty)
        #expect(store.projection(for: "session-a").runningJobID == nil)
    }

    @Test
    func applyEventReducesFromCurrentProjection() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()

        store.apply(
            runtimeSnapshot: SessionRuntimeSnapshot(
                sessionID: "session-a",
                queuedJobIDs: [jobID],
                runningJobID: nil,
                runningProviderReference: .builtIn,
                requestedCancellationJobIDs: [],
                lastAction: .enqueued,
                lastUpdatedAt: .now
            )
        )

        let projection = store.projection(for: "session-a")
        #expect(projection.queuedJobIDs == [jobID])
        #expect(projection.queuedCount == 1)
        #expect(projection.activityState == .queued)
        #expect(projection.activeProviderReference == .builtIn)
    }

    @Test
    func applyRuntimeSnapshotPreservesPresentationAndAttentionFields() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()
        store.apply(.presentationChanged(sessionID: "session-a", state: .background))

        store.apply(
            runtimeSnapshot: SessionRuntimeSnapshot(
                sessionID: "session-a",
                queuedJobIDs: [],
                runningJobID: jobID,
                runningProviderReference: .builtIn,
                requestedCancellationJobIDs: [],
                lastAction: .started,
                lastUpdatedAt: .now
            )
        )

        let projection = store.projection(for: "session-a")
        #expect(projection.runningJobID == jobID)
        #expect(projection.activityState == .running)
        #expect(projection.presentationState == .background)
        #expect(projection.needsAttention == false)
        #expect(projection.attentionReason == nil)
    }

    @Test
    func presentationChangedEventKeepsStoreAsOnlySourceOfTruth() {
        let store = ExecutionProjectionStore()
        let jobID = UUID()

        store.apply(
            runtimeSnapshot: SessionRuntimeSnapshot(
                sessionID: "session-a",
                queuedJobIDs: [],
                runningJobID: jobID,
                runningProviderReference: .builtIn,
                requestedCancellationJobIDs: [],
                lastAction: .started,
                lastUpdatedAt: .now
            )
        )
        store.apply(.presentationChanged(sessionID: "session-a", state: .background))

        let projection = store.projection(for: "session-a")
        #expect(projection.runningJobID == jobID)
        #expect(projection.presentationState == .background)
        #expect(projection.activityState == .running)
        #expect(projection.activeProviderReference == .builtIn)
    }
}