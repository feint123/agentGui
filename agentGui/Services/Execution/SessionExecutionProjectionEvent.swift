import Foundation

enum SessionExecutionProjectionEvent: Sendable, Equatable {
    case enqueued(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case recovered(sessionID: String, queuedJobIDs: [UUID], runningJobID: UUID?, providerReference: ExecutionProviderReference?)
    case started(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case cancelRequested(sessionID: String, jobID: UUID)
    case finished(sessionID: String, jobID: UUID, outcome: ExecutionJobState)
    case pruned(sessionID: String, jobID: UUID)
    case presentationChanged(sessionID: String, state: SessionExecutionPresentationState)

    var sessionID: String {
        switch self {
        case let .enqueued(sessionID, _, _),
             let .recovered(sessionID, _, _, _),
             let .started(sessionID, _, _),
             let .cancelRequested(sessionID, _),
             let .finished(sessionID, _, _),
             let .pruned(sessionID, _),
             let .presentationChanged(sessionID, _):
            return sessionID
        }
    }

    var runtimeEvent: SessionRuntimeEvent? {
        switch self {
        case let .enqueued(sessionID, jobID, providerReference):
            return .enqueued(sessionID: sessionID, jobID: jobID, providerReference: providerReference)
        case let .recovered(sessionID, queuedJobIDs, runningJobID, providerReference):
            return .recovered(
                sessionID: sessionID,
                queuedJobIDs: queuedJobIDs,
                runningJobID: runningJobID,
                providerReference: providerReference
            )
        case let .started(sessionID, jobID, providerReference):
            return .started(sessionID: sessionID, jobID: jobID, providerReference: providerReference)
        case let .cancelRequested(sessionID, jobID):
            return .cancelRequested(sessionID: sessionID, jobID: jobID)
        case let .finished(sessionID, jobID, outcome):
            return .finished(sessionID: sessionID, jobID: jobID, outcome: outcome)
        case let .pruned(sessionID, jobID):
            return .pruned(sessionID: sessionID, jobID: jobID)
        case .presentationChanged:
            return nil
        }
    }
}