import Foundation

enum SessionExecutionActivityState: String, Equatable, Sendable {
    case idle
    case queued
    case running
    case blocked
    case finishing
}

enum SessionExecutionPresentationState: String, Equatable, Sendable {
    case foreground
    case background
}

enum SessionExecutionAttentionReason: String, Equatable, Sendable {
    case userQuestion
    case toolApproval
    case terminalPrompt
}

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
    let activityState: SessionExecutionActivityState
    let presentationState: SessionExecutionPresentationState
    let needsAttention: Bool
    let attentionReason: SessionExecutionAttentionReason?

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
            currentPhase: nil,
            activityState: .idle,
            presentationState: .foreground,
            needsAttention: false,
            attentionReason: nil
        )
    }
}