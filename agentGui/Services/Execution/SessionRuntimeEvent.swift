import Foundation

enum SessionRuntimeEvent: Sendable, Equatable {
    case enqueued(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case recovered(sessionID: String, queuedJobIDs: [UUID], runningJobID: UUID?, providerReference: ExecutionProviderReference?)
    case started(sessionID: String, jobID: UUID, providerReference: ExecutionProviderReference)
    case cancelRequested(sessionID: String, jobID: UUID)
    case finished(sessionID: String, jobID: UUID, outcome: ExecutionJobState)
    case pruned(sessionID: String, jobID: UUID)

    var sessionID: String {
        switch self {
        case let .enqueued(sessionID, _, _),
             let .recovered(sessionID, _, _, _),
             let .started(sessionID, _, _),
             let .cancelRequested(sessionID, _),
             let .finished(sessionID, _, _),
             let .pruned(sessionID, _):
            return sessionID
        }
    }
}