import Foundation

enum SessionRuntimeSnapshotReducer {
    static func reduce(
        current: SessionRuntimeSnapshot,
        event: SessionRuntimeEvent,
        now: Date = Date()
    ) -> SessionRuntimeSnapshot {
        switch event {
        case let .enqueued(sessionID, jobID, providerReference):
            let queuedJobIDs = current.queuedJobIDs.contains(jobID)
                ? current.queuedJobIDs
                : current.queuedJobIDs + [jobID]
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs,
                runningJobID: current.runningJobID,
                runningProviderReference: current.runningProviderReference,
                requestedCancellationJobIDs: current.requestedCancellationJobIDs,
                lastAction: .enqueued,
                lastUpdatedAt: now,
                lastKnownProviderReference: providerReference
            )

        case let .recovered(sessionID, queuedJobIDs, runningJobID, providerReference):
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs.filter { $0 != runningJobID },
                runningJobID: runningJobID,
                runningProviderReference: runningJobID == nil ? nil : providerReference,
                requestedCancellationJobIDs: [],
                lastAction: .recovered,
                lastUpdatedAt: now,
                lastKnownProviderReference: providerReference
            )

        case let .started(sessionID, jobID, providerReference):
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: current.queuedJobIDs.filter { $0 != jobID },
                runningJobID: jobID,
                runningProviderReference: providerReference,
                requestedCancellationJobIDs: current.requestedCancellationJobIDs.filter { $0 == jobID },
                lastAction: .started,
                lastUpdatedAt: now,
                lastKnownProviderReference: providerReference
            )

        case let .cancelRequested(sessionID, jobID):
            let requestedCancellationJobIDs = current.requestedCancellationJobIDs.contains(jobID)
                ? current.requestedCancellationJobIDs
                : current.requestedCancellationJobIDs + [jobID]
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: current.queuedJobIDs,
                runningJobID: current.runningJobID,
                runningProviderReference: current.runningProviderReference,
                requestedCancellationJobIDs: requestedCancellationJobIDs,
                lastAction: .cancelRequested,
                lastUpdatedAt: now,
                lastKnownProviderReference: current.lastKnownProviderReference
            )

        case let .finished(sessionID, jobID, outcome):
            let isCurrentRunningJob = current.runningJobID == jobID
            let queuedJobIDs = current.queuedJobIDs
            let nextRunningJobID = isCurrentRunningJob ? nil : current.runningJobID
            let nextRunningProviderReference = isCurrentRunningJob ? nil : current.runningProviderReference
            let lastKnownProviderReference = (nextRunningProviderReference != nil || queuedJobIDs.isEmpty == false)
                ? (nextRunningProviderReference ?? current.lastKnownProviderReference)
                : nil
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs,
                runningJobID: nextRunningJobID,
                runningProviderReference: nextRunningProviderReference,
                requestedCancellationJobIDs: current.requestedCancellationJobIDs.filter { $0 != jobID },
                lastAction: .finished(outcome),
                lastUpdatedAt: now,
                lastKnownProviderReference: lastKnownProviderReference
            )

        case let .pruned(sessionID, jobID):
            let queuedJobIDs = current.queuedJobIDs.filter { $0 != jobID }
            let lastKnownProviderReference = (current.runningProviderReference != nil || queuedJobIDs.isEmpty == false)
                ? current.lastKnownProviderReference
                : nil
            return SessionRuntimeSnapshot(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs,
                runningJobID: current.runningJobID,
                runningProviderReference: current.runningProviderReference,
                requestedCancellationJobIDs: current.requestedCancellationJobIDs,
                lastAction: .pruned,
                lastUpdatedAt: now,
                lastKnownProviderReference: lastKnownProviderReference
            )
        }
    }
}