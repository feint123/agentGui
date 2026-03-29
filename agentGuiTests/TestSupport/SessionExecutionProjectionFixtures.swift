import Foundation
@testable import agentGui

extension SessionExecutionProjection {
    static func fixture(
        sessionID: String = "session-a",
        runningJobID: UUID? = nil,
        queuedJobIDs: [UUID] = [],
        isRunning: Bool? = nil,
        canEditComposer: Bool = true,
        canSubmitNewJob: Bool = true,
        activeProviderID: ConversationExecutionProviderID? = nil,
        activeProviderReference: ExecutionProviderReference? = nil,
        currentPhase: AgentLoopPhase? = nil,
        activityState: SessionExecutionActivityState = .idle,
        presentationState: SessionExecutionPresentationState = .foreground,
        needsAttention: Bool = false,
        attentionReason: SessionExecutionAttentionReason? = nil
    ) -> SessionExecutionProjection {
        SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: runningJobID,
            queuedJobIDs: queuedJobIDs,
            queuedCount: queuedJobIDs.count,
            isRunning: isRunning ?? (runningJobID != nil),
            canEditComposer: canEditComposer,
            canSubmitNewJob: canSubmitNewJob,
            activeProviderReference: activeProviderReference ?? ExecutionProviderReference.compatibilityReference(for: activeProviderID),
            currentPhase: currentPhase,
            activityState: activityState,
            presentationState: presentationState,
            needsAttention: needsAttention,
            attentionReason: attentionReason
        )
    }
}