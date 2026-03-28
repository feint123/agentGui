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
    let providerReference: ExecutionProviderReference
    let payload: ExecutionPayloadDraft
    let sourceUserMessageID: UUID

    init(
        sessionID: String,
        providerID: ConversationExecutionProviderID,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) {
        self.init(
            sessionID: sessionID,
            providerReference: ExecutionProviderReference.compatibilityReference(for: providerID) ?? .builtIn,
            payload: payload,
            sourceUserMessageID: sourceUserMessageID
        )
    }

    init(
        sessionID: String,
        providerReference: ExecutionProviderReference,
        payload: ExecutionPayloadDraft,
        sourceUserMessageID: UUID
    ) {
        self.sessionID = sessionID
        self.providerReference = providerReference
        self.payload = payload
        self.sourceUserMessageID = sourceUserMessageID
    }

    var providerID: ConversationExecutionProviderID {
        providerReference.compatibilityProviderID ?? .builtInAgent
    }
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
    let activeProviderReference: ExecutionProviderReference?
    let currentPhase: AgentLoopPhase?
    let activityState: SessionExecutionActivityState
    let presentationState: SessionExecutionPresentationState
    let needsAttention: Bool
    let attentionReason: SessionExecutionAttentionReason?

    private static func reference(for providerID: ConversationExecutionProviderID?) -> ExecutionProviderReference? {
        ExecutionProviderReference.compatibilityReference(for: providerID)
    }

    init(
        sessionID: String,
        runningJobID: UUID?,
        queuedJobIDs: [UUID],
        queuedCount: Int,
        isRunning: Bool,
        canEditComposer: Bool,
        canSubmitNewJob: Bool,
        activeProviderID: ConversationExecutionProviderID?,
        currentPhase: AgentLoopPhase?,
        activityState: SessionExecutionActivityState,
        presentationState: SessionExecutionPresentationState,
        needsAttention: Bool,
        attentionReason: SessionExecutionAttentionReason?
    ) {
        self.init(
            sessionID: sessionID,
            runningJobID: runningJobID,
            queuedJobIDs: queuedJobIDs,
            queuedCount: queuedCount,
            isRunning: isRunning,
            canEditComposer: canEditComposer,
            canSubmitNewJob: canSubmitNewJob,
            activeProviderReference: Self.reference(for: activeProviderID),
            currentPhase: currentPhase,
            activityState: activityState,
            presentationState: presentationState,
            needsAttention: needsAttention,
            attentionReason: attentionReason
        )
    }

    init(
        sessionID: String,
        runningJobID: UUID?,
        queuedJobIDs: [UUID],
        queuedCount: Int,
        isRunning: Bool,
        canEditComposer: Bool,
        canSubmitNewJob: Bool,
        activeProviderReference: ExecutionProviderReference?,
        currentPhase: AgentLoopPhase?,
        activityState: SessionExecutionActivityState,
        presentationState: SessionExecutionPresentationState,
        needsAttention: Bool,
        attentionReason: SessionExecutionAttentionReason?
    ) {
        self.sessionID = sessionID
        self.runningJobID = runningJobID
        self.queuedJobIDs = queuedJobIDs
        self.queuedCount = queuedCount
        self.isRunning = isRunning
        self.canEditComposer = canEditComposer
        self.canSubmitNewJob = canSubmitNewJob
        self.activeProviderReference = activeProviderReference
        self.currentPhase = currentPhase
        self.activityState = activityState
        self.presentationState = presentationState
        self.needsAttention = needsAttention
        self.attentionReason = attentionReason
    }

    var activeProviderID: ConversationExecutionProviderID? {
        activeProviderReference?.compatibilityProviderID
    }

    static func empty(sessionID: String) -> SessionExecutionProjection {
        SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: nil,
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: false,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderReference: nil,
            currentPhase: nil,
            activityState: .idle,
            presentationState: .foreground,
            needsAttention: false,
            attentionReason: nil
        )
    }
}