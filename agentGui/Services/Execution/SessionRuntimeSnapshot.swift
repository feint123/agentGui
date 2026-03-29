import Foundation

struct SessionRuntimeSnapshot: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case idle
        case enqueued
        case recovered
        case started
        case cancelRequested
        case finished(ExecutionJobState)
        case pruned
    }

    let sessionID: String
    let queuedJobIDs: [UUID]
    let runningJobID: UUID?
    let runningProviderReference: ExecutionProviderReference?
    let lastKnownProviderReference: ExecutionProviderReference?
    let requestedCancellationJobIDs: [UUID]
    let lastAction: Action
    let lastUpdatedAt: Date

    init(
        sessionID: String,
        queuedJobIDs: [UUID],
        runningJobID: UUID?,
        runningProviderReference: ExecutionProviderReference?,
        requestedCancellationJobIDs: [UUID],
        lastAction: Action,
        lastUpdatedAt: Date,
        lastKnownProviderReference: ExecutionProviderReference? = nil
    ) {
        self.sessionID = sessionID
        self.queuedJobIDs = queuedJobIDs
        self.runningJobID = runningJobID
        self.runningProviderReference = runningProviderReference
        self.lastKnownProviderReference = lastKnownProviderReference ?? runningProviderReference
        self.requestedCancellationJobIDs = requestedCancellationJobIDs
        self.lastAction = lastAction
        self.lastUpdatedAt = lastUpdatedAt
    }

    var isRunning: Bool {
        runningJobID != nil && runningProviderReference != nil
    }

    var isCancelling: Bool {
        guard let runningJobID else {
            return false
        }

        return requestedCancellationJobIDs.contains(runningJobID)
    }

    static func empty(sessionID: String) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot(
            sessionID: sessionID,
            queuedJobIDs: [],
            runningJobID: nil,
            runningProviderReference: nil,
            requestedCancellationJobIDs: [],
            lastAction: .idle,
            lastUpdatedAt: .distantPast,
            lastKnownProviderReference: nil
        )
    }
}