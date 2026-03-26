import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerExecutionPresentationTests {
    @Test
    func blockedAttentionOnlyProjectionStillUsesProjectionUI() {
        let projection = SessionExecutionProjection(
            sessionID: "session-a",
            runningJobID: nil,
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: false,
            canEditComposer: false,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent,
            currentPhase: nil,
            activityState: .blocked,
            presentationState: .background,
            needsAttention: true,
            attentionReason: .userQuestion
        )

        #expect(ChatComposerExecutionPresentation.shouldUseExecutionProjectionUI(for: projection))
    }

    @Test
    func backgroundRunningProjectionShowsStatusBadge() {
        let projection = SessionExecutionProjection(
            sessionID: "session-a",
            runningJobID: UUID(),
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: true,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent,
            currentPhase: .executing,
            activityState: .running,
            presentationState: .background,
            needsAttention: false,
            attentionReason: nil
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: true,
            projection: projection,
            legacyIsStreaming: false,
            canSend: true
        )

        #expect(presentation.showsRunningBadge)
        #expect(presentation.statusBadgeText == "后台运行")
    }

    @Test
    func blockedProjectionShowsAttentionStatusBadge() {
        let projection = SessionExecutionProjection(
            sessionID: "session-a",
            runningJobID: UUID(),
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: true,
            canEditComposer: false,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent,
            currentPhase: .executing,
            activityState: .blocked,
            presentationState: .background,
            needsAttention: true,
            attentionReason: .userQuestion
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: true,
            projection: projection,
            legacyIsStreaming: false,
            canSend: true
        )

        #expect(presentation.showsRunningBadge)
        #expect(presentation.statusBadgeText == "等待处理")
    }
}