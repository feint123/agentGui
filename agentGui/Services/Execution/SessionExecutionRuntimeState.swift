import Foundation

struct SessionExecutionRuntimeState: Equatable, Sendable {
    let sessionID: String
    let queuedJobIDs: [UUID]
    let runningJobID: UUID?
    let runningProviderReference: ExecutionProviderReference?

    var isRunning: Bool {
        runningJobID != nil && runningProviderReference != nil
    }

    static func empty(sessionID: String) -> SessionExecutionRuntimeState {
        SessionExecutionRuntimeState(
            sessionID: sessionID,
            queuedJobIDs: [],
            runningJobID: nil,
            runningProviderReference: nil
        )
    }
}