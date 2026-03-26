import Foundation
import Observation

@Observable
@MainActor
final class SessionExecutionController {
    let sessionID: String

    private let projectionStore: ExecutionProjectionStore?
    private(set) var projection: SessionExecutionProjection {
        didSet {
            projectionStore?.setProjection(projection)
        }
    }

    init(
        sessionID: String,
        projectionStore: ExecutionProjectionStore? = nil,
        initialProjection: SessionExecutionProjection? = nil
    ) {
        self.sessionID = sessionID
        self.projectionStore = projectionStore
        self.projection = initialProjection ?? projectionStore?.projection(for: sessionID) ?? .empty(sessionID: sessionID)
        projectionStore?.setProjection(self.projection)
    }

    func syncFromStore() {
        guard let projectionStore else {
            return
        }

        let latestProjection = projectionStore.projection(for: sessionID)
        guard latestProjection != projection else {
            return
        }

        projection = latestProjection
    }

    func recordQueued(
        queuedJobIDs: [UUID],
        providerID: ConversationExecutionProviderID?,
        currentPhase: AgentLoopPhase? = nil
    ) {
        let isRunning = projection.isRunning
        projection = SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: projection.runningJobID,
            queuedJobIDs: queuedJobIDs,
            queuedCount: queuedJobIDs.count,
            isRunning: isRunning,
            canEditComposer: projection.canEditComposer,
            canSubmitNewJob: projection.canSubmitNewJob,
            activeProviderID: providerID ?? projection.activeProviderID,
            currentPhase: currentPhase ?? projection.currentPhase,
            activityState: isRunning ? .running : (queuedJobIDs.isEmpty ? .idle : .queued),
            presentationState: projection.presentationState,
            needsAttention: projection.needsAttention,
            attentionReason: projection.attentionReason
        )
    }

    func recordRunning(
        jobID: UUID?,
        providerID: ConversationExecutionProviderID?,
        currentPhase: AgentLoopPhase?
    ) {
        projection = SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: jobID,
            queuedJobIDs: projection.queuedJobIDs,
            queuedCount: projection.queuedJobIDs.count,
            isRunning: true,
            canEditComposer: projection.canEditComposer,
            canSubmitNewJob: projection.canSubmitNewJob,
            activeProviderID: providerID ?? projection.activeProviderID,
            currentPhase: currentPhase,
            activityState: .running,
            presentationState: projection.presentationState,
            needsAttention: projection.needsAttention,
            attentionReason: projection.attentionReason
        )
    }

    func recordBlocked(_ reason: SessionExecutionAttentionReason) {
        projection = SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: projection.runningJobID,
            queuedJobIDs: projection.queuedJobIDs,
            queuedCount: projection.queuedJobIDs.count,
            isRunning: projection.isRunning,
            canEditComposer: projection.canEditComposer,
            canSubmitNewJob: projection.canSubmitNewJob,
            activeProviderID: projection.activeProviderID,
            currentPhase: projection.currentPhase,
            activityState: .blocked,
            presentationState: projection.presentationState,
            needsAttention: true,
            attentionReason: reason
        )
    }

    func recordIdle() {
        projection = SessionExecutionProjection(
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
            presentationState: projection.presentationState,
            needsAttention: false,
            attentionReason: nil
        )
    }

    func setPresentationState(_ state: SessionExecutionPresentationState) {
        projection = SessionExecutionProjection(
            sessionID: sessionID,
            runningJobID: projection.runningJobID,
            queuedJobIDs: projection.queuedJobIDs,
            queuedCount: projection.queuedJobIDs.count,
            isRunning: projection.isRunning,
            canEditComposer: projection.canEditComposer,
            canSubmitNewJob: projection.canSubmitNewJob,
            activeProviderID: projection.activeProviderID,
            currentPhase: projection.currentPhase,
            activityState: projection.activityState,
            presentationState: state,
            needsAttention: projection.needsAttention,
            attentionReason: projection.attentionReason
        )
    }
}