import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionExecutionProjectionReducerTests {
    @Test
    func enqueueEventAppendsQueuedJobAndMarksQueued() {
        let jobID = UUID()

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .enqueued(
                sessionID: "session-a",
                jobID: jobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.queuedJobIDs == [jobID])
        #expect(reduced.queuedCount == 1)
        #expect(reduced.activityState == .queued)
        #expect(reduced.activeProviderReference == .builtIn)
    }

    @Test
    func startEventMovesJobFromQueueToRunning() {
        let firstJobID = UUID()
        let secondJobID = UUID()
        let current = SessionExecutionProjection.fixture(
            queuedJobIDs: [firstJobID, secondJobID],
            activeProviderReference: .builtIn,
            activityState: .queued
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: .started(
                sessionID: "session-a",
                jobID: firstJobID,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == firstJobID)
        #expect(reduced.queuedJobIDs == [secondJobID])
        #expect(reduced.isRunning)
        #expect(reduced.currentPhase == .executing)
        #expect(reduced.activityState == .running)
    }

    @Test
    func cancelledFinishClearsRunningAndKeepsQueuedTailReady() {
        let runningJobID = UUID()
        let queuedJobID = UUID()
        let current = SessionExecutionProjection.fixture(
            runningJobID: runningJobID,
            queuedJobIDs: [queuedJobID],
            isRunning: true,
            activeProviderReference: .builtIn,
            currentPhase: .executing,
            activityState: .running
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: .finished(
                sessionID: "session-a",
                jobID: runningJobID,
                outcome: .cancelled
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.queuedJobIDs == [queuedJobID])
        #expect(reduced.isRunning == false)
        #expect(reduced.currentPhase == nil)
        #expect(reduced.activityState == .queued)
    }

    @Test
    func failedFinishClearsRunningAndFallsBackToIdleWhenQueueIsEmpty() {
        let jobID = UUID()
        let current = SessionExecutionProjection.fixture(
            runningJobID: jobID,
            isRunning: true,
            activeProviderReference: .builtIn,
            currentPhase: .executing,
            activityState: .running
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: .finished(
                sessionID: "session-a",
                jobID: jobID,
                outcome: .failed
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.isRunning == false)
        #expect(reduced.currentPhase == nil)
        #expect(reduced.activityState == .idle)
        #expect(reduced.activeProviderReference == nil)
    }

    @Test
    func recoveredEventRebuildsQueuedProjection() {
        let firstJobID = UUID()
        let secondJobID = UUID()

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: .empty(sessionID: "session-a"),
            event: .recovered(
                sessionID: "session-a",
                queuedJobIDs: [firstJobID, secondJobID],
                runningJobID: nil,
                providerReference: .builtIn
            )
        )

        #expect(reduced.runningJobID == nil)
        #expect(reduced.queuedJobIDs == [firstJobID, secondJobID])
        #expect(reduced.queuedCount == 2)
        #expect(reduced.activityState == .queued)
        #expect(reduced.activeProviderReference == .builtIn)
    }

    @Test
    func pruneEventRemovesQueuedJobWithoutChangingOtherFields() {
        let prunedJobID = UUID()
        let remainingJobID = UUID()
        let current = SessionExecutionProjection.fixture(
            queuedJobIDs: [prunedJobID, remainingJobID],
            activeProviderReference: .builtIn,
            activityState: .queued,
            presentationState: .background,
            needsAttention: true,
            attentionReason: .userQuestion,
        )

        let reduced = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: .pruned(sessionID: "session-a", jobID: prunedJobID)
        )

        #expect(reduced.queuedJobIDs == [remainingJobID])
        #expect(reduced.queuedCount == 1)
        #expect(reduced.presentationState == .background)
        #expect(reduced.needsAttention)
        #expect(reduced.attentionReason == .userQuestion)
        #expect(reduced.activeProviderReference == .builtIn)
    }
}