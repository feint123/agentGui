import Foundation

enum SessionExecutionProjectionReducer {
    static func reduce(
        current: SessionExecutionProjection,
        event: SessionExecutionProjectionEvent
    ) -> SessionExecutionProjection {
        switch event {
        case let .enqueued(sessionID, jobID, providerReference):
            let queuedJobIDs = current.queuedJobIDs.contains(jobID)
                ? current.queuedJobIDs
                : current.queuedJobIDs + [jobID]
            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: current.runningJobID,
                queuedJobIDs: queuedJobIDs,
                isRunning: current.isRunning,
                activeProviderReference: providerReference,
                currentPhase: current.currentPhase,
                activityState: current.isRunning ? .running : (queuedJobIDs.isEmpty ? .idle : .queued),
                needsAttention: current.needsAttention,
                attentionReason: current.attentionReason
            )

        case let .recovered(sessionID, queuedJobIDs, runningJobID, providerReference):
            let filteredQueuedJobIDs = queuedJobIDs.filter { $0 != runningJobID }
            let isRunning = runningJobID != nil
            let activityState: SessionExecutionActivityState
            if isRunning {
                activityState = .running
            } else if filteredQueuedJobIDs.isEmpty {
                activityState = .idle
            } else {
                activityState = .queued
            }

            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: runningJobID,
                queuedJobIDs: filteredQueuedJobIDs,
                isRunning: isRunning,
                activeProviderReference: providerReference,
                currentPhase: isRunning ? .executing : nil,
                activityState: activityState,
                needsAttention: false,
                attentionReason: nil
            )

        case let .started(sessionID, jobID, providerReference):
            let queuedJobIDs = current.queuedJobIDs.filter { $0 != jobID }
            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: jobID,
                queuedJobIDs: queuedJobIDs,
                isRunning: true,
                activeProviderReference: providerReference,
                currentPhase: .executing,
                activityState: .running,
                needsAttention: current.needsAttention,
                attentionReason: current.attentionReason
            )

        case let .finished(sessionID, jobID, _):
            let runningJobID = current.runningJobID == jobID ? nil : current.runningJobID
            let isRunning = runningJobID != nil
            let activeProviderReference = (isRunning || current.queuedJobIDs.isEmpty == false)
                ? current.activeProviderReference
                : nil
            let activityState: SessionExecutionActivityState
            if isRunning {
                activityState = .running
            } else if current.queuedJobIDs.isEmpty {
                activityState = .idle
            } else {
                activityState = .queued
            }

            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: runningJobID,
                queuedJobIDs: current.queuedJobIDs,
                isRunning: isRunning,
                activeProviderReference: activeProviderReference,
                currentPhase: isRunning ? current.currentPhase : nil,
                activityState: activityState,
                needsAttention: false,
                attentionReason: nil
            )

        case let .pruned(sessionID, jobID):
            let queuedJobIDs = current.queuedJobIDs.filter { $0 != jobID }
            let activeProviderReference = (current.isRunning || queuedJobIDs.isEmpty == false)
                ? current.activeProviderReference
                : nil
            let activityState: SessionExecutionActivityState
            if current.isRunning {
                activityState = .running
            } else if queuedJobIDs.isEmpty {
                activityState = .idle
            } else {
                activityState = .queued
            }

            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: current.runningJobID,
                queuedJobIDs: queuedJobIDs,
                isRunning: current.isRunning,
                activeProviderReference: activeProviderReference,
                currentPhase: current.currentPhase,
                activityState: activityState,
                needsAttention: current.needsAttention,
                attentionReason: current.attentionReason
            )

        case let .presentationChanged(sessionID, state):
            return projection(
                from: current,
                sessionID: sessionID,
                runningJobID: current.runningJobID,
                queuedJobIDs: current.queuedJobIDs,
                isRunning: current.isRunning,
                activeProviderReference: current.activeProviderReference,
                currentPhase: current.currentPhase,
                activityState: current.activityState,
                presentationState: state,
                needsAttention: current.needsAttention,
                attentionReason: current.attentionReason
            )
        }
    }

    private static func projection(
        from current: SessionExecutionProjection,
        sessionID: String,
        runningJobID: UUID?,
        queuedJobIDs: [UUID],
        isRunning: Bool,
        activeProviderReference: ExecutionProviderReference?,
        currentPhase: AgentLoopPhase?,
        activityState: SessionExecutionActivityState,
        presentationState: SessionExecutionPresentationState? = nil,
        needsAttention: Bool,
        attentionReason: SessionExecutionAttentionReason?
    ) -> SessionExecutionProjection {
        SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: runningJobID,
            queuedJobIDs: queuedJobIDs,
            queuedCount: queuedJobIDs.count,
            isRunning: isRunning,
            canEditComposer: current.canEditComposer,
            canSubmitNewJob: current.canSubmitNewJob,
            activeProviderReference: activeProviderReference,
            currentPhase: currentPhase,
            activityState: activityState,
            presentationState: presentationState ?? current.presentationState,
            needsAttention: needsAttention,
            attentionReason: attentionReason
        )
    }
}