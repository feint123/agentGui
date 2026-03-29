import Foundation

enum SessionExecutionRuntimeStateReducer {
    static func reduce(
        current: SessionExecutionRuntimeState,
        event: SessionExecutionProjectionEvent
    ) -> SessionExecutionRuntimeState {
        switch event {
        case let .enqueued(sessionID, jobID, _):
            let queuedJobIDs = current.queuedJobIDs.contains(jobID)
                ? current.queuedJobIDs
                : current.queuedJobIDs + [jobID]
            return SessionExecutionRuntimeState(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs,
                runningJobID: current.runningJobID,
                runningProviderReference: current.runningProviderReference
            )

        case let .recovered(sessionID, queuedJobIDs, runningJobID, providerReference):
            return SessionExecutionRuntimeState(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs.filter { $0 != runningJobID },
                runningJobID: runningJobID,
                runningProviderReference: runningJobID == nil ? nil : providerReference
            )

        case let .started(sessionID, jobID, providerReference):
            return SessionExecutionRuntimeState(
                sessionID: sessionID,
                queuedJobIDs: current.queuedJobIDs.filter { $0 != jobID },
                runningJobID: jobID,
                runningProviderReference: providerReference
            )

        case let .finished(sessionID, jobID, _):
            let isCurrentRunningJob = current.runningJobID == jobID
            return SessionExecutionRuntimeState(
                sessionID: sessionID,
                queuedJobIDs: current.queuedJobIDs,
                runningJobID: isCurrentRunningJob ? nil : current.runningJobID,
                runningProviderReference: isCurrentRunningJob ? nil : current.runningProviderReference
            )

        case let .pruned(sessionID, jobID):
            return SessionExecutionRuntimeState(
                sessionID: sessionID,
                queuedJobIDs: current.queuedJobIDs.filter { $0 != jobID },
                runningJobID: current.runningJobID,
                runningProviderReference: current.runningProviderReference
            )

        case .presentationChanged:
            return current
        }
    }
}