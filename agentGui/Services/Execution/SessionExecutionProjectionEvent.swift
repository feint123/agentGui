import Foundation

enum SessionExecutionProjectionEvent: Sendable, Equatable {
    case enqueued(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case recovered(sessionID: String, queuedJobIDs: [UUID], runningJobID: UUID?, providerReference: ExecutionProviderReference?)
    case started(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case finished(sessionID: String, jobID: UUID, outcome: ExecutionJobState)
    case pruned(sessionID: String, jobID: UUID)
    case presentationChanged(sessionID: String, state: SessionExecutionPresentationState)

    var sessionID: String {
        switch self {
        case let .enqueued(sessionID, _, _),
             let .recovered(sessionID, _, _, _),
             let .started(sessionID, _, _),
             let .finished(sessionID, _, _),
             let .pruned(sessionID, _),
             let .presentationChanged(sessionID, _):
            return sessionID
        }
    }
}