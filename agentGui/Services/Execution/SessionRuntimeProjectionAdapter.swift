import Foundation

enum SessionRuntimeProjectionAdapter {
    static func project(
        current: SessionExecutionProjection,
        runtimeSnapshot: SessionRuntimeSnapshot
    ) -> SessionExecutionProjection {
        let activeProviderReference = runtimeSnapshot.runningProviderReference
            ?? runtimeSnapshot.lastKnownProviderReference
        let activityState: SessionExecutionActivityState
        let currentPhase: AgentLoopPhase?

        if runtimeSnapshot.isRunning {
            activityState = .running
            currentPhase = .executing
        } else if runtimeSnapshot.queuedJobIDs.isEmpty {
            activityState = .idle
            currentPhase = nil
        } else {
            activityState = .queued
            currentPhase = nil
        }

        return SessionExecutionProjection(
            sessionID: runtimeSnapshot.sessionID,
            runningJobID: runtimeSnapshot.runningJobID,
            queuedJobIDs: runtimeSnapshot.queuedJobIDs,
            queuedCount: runtimeSnapshot.queuedJobIDs.count,
            isRunning: runtimeSnapshot.isRunning,
            canEditComposer: current.canEditComposer,
            canSubmitNewJob: current.canSubmitNewJob,
            activeProviderReference: activeProviderReference,
            currentPhase: currentPhase,
            activityState: activityState,
            presentationState: current.presentationState,
            needsAttention: current.needsAttention,
            attentionReason: current.attentionReason
        )
    }
}