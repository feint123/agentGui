import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionRuntimeStateReducerTests {
    @Test
    func startEventMarksRuntimeRunningForProviderReference() {
        let jobID = UUID()

        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .started(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == jobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.isRunning)
    }

    @Test
    func finishedEventClearsRunningLeaseButKeepsQueuedBookkeeping() {
        let runningJobID = UUID()
        let queuedJobID = UUID()
        let current = SessionExecutionRuntimeState(
            sessionID: "session-a",
            queuedJobIDs: [queuedJobID],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn
        )

        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: current,
            event: .finished(
                sessionID: "session-a",
                jobID: runningJobID,
                outcome: .completed
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.runningProviderReference == nil)
        #expect(reduced.isRunning == false)
        #expect(reduced.queuedJobIDs == [queuedJobID])
    }

    @Test
    func recoveredEventRestoresRunningLeaseWhenRunningJobExists() {
        let queuedJobID = UUID()
        let runningJobID = UUID()

        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .recovered(
                sessionID: "session-a",
                queuedJobIDs: [queuedJobID, runningJobID],
                runningJobID: runningJobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == runningJobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.queuedJobIDs == [queuedJobID])
        #expect(reduced.isRunning)
    }

    @Test
    func prunedEventOnlyUpdatesQueuedBookkeeping() {
        let prunedJobID = UUID()
        let remainingJobID = UUID()
        let runningJobID = UUID()
        let current = SessionExecutionRuntimeState(
            sessionID: "session-a",
            queuedJobIDs: [prunedJobID, remainingJobID],
            runningJobID: runningJobID,
            runningProviderReference: .builtIn
        )

        let reduced = SessionExecutionRuntimeStateReducer.reduce(
            current: current,
            event: .pruned(sessionID: "session-a", jobID: prunedJobID)
        )

        #expect(reduced.queuedJobIDs == [remainingJobID])
        #expect(reduced.runningJobID == runningJobID)
        #expect(reduced.runningProviderReference == .builtIn)
        #expect(reduced.isRunning)
    }
}