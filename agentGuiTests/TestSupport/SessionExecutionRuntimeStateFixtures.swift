import Foundation
@testable import agentGui

extension SessionExecutionRuntimeState {
    static func fixture(
        sessionID: String = "session-a",
        queuedJobIDs: [UUID] = [],
        runningJobID: UUID? = nil,
        runningProviderReference: ExecutionProviderReference? = nil
    ) -> SessionExecutionRuntimeState {
        SessionExecutionRuntimeState(
            sessionID: sessionID,
            queuedJobIDs: queuedJobIDs,
            runningJobID: runningJobID,
            runningProviderReference: runningProviderReference
        )
    }
}