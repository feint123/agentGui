import Foundation
import Testing
@testable import agentGui

struct SessionRuntimeSnapshotReducerTests {
    @Test
    func enqueueAppendsQueuedJobAndMarksLastAction() {
        let jobID = UUID()

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .enqueued(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.queuedJobIDs == [jobID])
        #expect(reduced.lastAction == .enqueued)
    }

    @Test
    func startMovesJobToRunningAndPersistsProviderReference() {
        let runningJobID = UUID()
        let queuedJobID = UUID()
        let current = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [runningJobID, queuedJobID],
            runningJobID: nil,
            runningProviderReference: nil,
            requestedCancellationJobIDs: [],
            lastAction: .enqueued,
            lastUpdatedAt: .distantPast
        )

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: current,
            event: .started(
                sessionID: "session-a",
                jobID: runningJobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == runningJobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.queuedJobIDs == [queuedJobID])
        #expect(reduced.lastAction == .started)
    }

    @Test
    func recoveredRebuildsQueuedAndRunningState() {
        let queuedJobID = UUID()
        let runningJobID = UUID()

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .recovered(
                sessionID: "session-a",
                queuedJobIDs: [queuedJobID, runningJobID],
                runningJobID: runningJobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.queuedJobIDs == [queuedJobID])
        #expect(reduced.runningJobID == runningJobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.lastAction == .recovered)
    }

    @Test
    func cancelRequestedMarksRunningSnapshotAsCancelling() {
        let runningJobID = UUID()
        let current = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [],
            lastAction: .started,
            lastUpdatedAt: .distantPast
        )

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: current,
            event: .cancelRequested(sessionID: "session-a", jobID: runningJobID)
        )

        #expect(reduced.isRunning)
        #expect(reduced.isCancelling)
        #expect(reduced.requestedCancellationJobIDs == [runningJobID])
        #expect(reduced.lastAction == .cancelRequested)
    }

    @Test
    func cancelledFinishClearsRunningAndCancellationStateWhileKeepingQueuedTail() {
        let runningJobID = UUID()
        let queuedJobID = UUID()
        let current = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [queuedJobID],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [runningJobID],
            lastAction: .cancelRequested,
            lastUpdatedAt: .distantPast
        )

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: current,
            event: .finished(
                sessionID: "session-a",
                jobID: runningJobID,
                outcome: .cancelled
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.runningProviderReference == nil)
        #expect(reduced.requestedCancellationJobIDs.isEmpty)
        #expect(reduced.queuedJobIDs == [queuedJobID])
        #expect(reduced.lastAction == .finished(.cancelled))
    }

    @Test
    func pruneOnlyUpdatesQueueState() {
        let prunedJobID = UUID()
        let runningJobID = UUID()
        let current = SessionRuntimeSnapshot(
            sessionID: "session-a",
            queuedJobIDs: [prunedJobID],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn,
            requestedCancellationJobIDs: [],
            lastAction: .started,
            lastUpdatedAt: .distantPast
        )

        let reduced = SessionRuntimeSnapshotReducer.reduce(
            current: current,
            event: .pruned(sessionID: "session-a", jobID: prunedJobID)
        )

        #expect(reduced.queuedJobIDs.isEmpty)
        #expect(reduced.runningJobID == runningJobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.lastAction == .pruned)
    }
}