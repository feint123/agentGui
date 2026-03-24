import Foundation

struct EnqueueExecutionCommand: Sendable {
    let sessionID: String
    let providerID: ConversationExecutionProviderID
    let payload: ExecutionPayloadDraft
    let sourceUserMessageID: UUID
}

struct ExecutionJobHandle: Equatable, Sendable {
    let jobID: UUID
    let sessionID: String
}

struct SessionExecutionProjection: Equatable, Sendable {
    let sessionID: String
    let runningJobID: UUID?
    let queuedJobIDs: [UUID]
    let queuedCount: Int
    let isRunning: Bool
    let canEditComposer: Bool
    let canSubmitNewJob: Bool
    let activeProviderID: ConversationExecutionProviderID?
    let currentPhase: AgentLoopPhase?

    static func empty(sessionID: String) -> SessionExecutionProjection {
        SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: nil,
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: false,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderID: nil,
            currentPhase: nil
        )
    }
}