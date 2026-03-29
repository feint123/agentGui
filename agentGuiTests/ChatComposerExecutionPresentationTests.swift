import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerExecutionPresentationTests {
    @Test
    func blockedAttentionOnlyProjectionStillUsesProjectionUI() {
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            canEditComposer: false,
            activeProviderID: .builtInAgent,
            activityState: .blocked,
            presentationState: .background,
            needsAttention: true,
            attentionReason: .userQuestion
        )

        #expect(ChatComposerExecutionPresentation.shouldUseExecutionProjectionUI(for: projection))
    }

    @Test
    func runningBackgroundProjectionStillUsesProjectionUI() {
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            runningJobID: UUID(),
            activeProviderID: .builtInAgent,
            activityState: .running,
            presentationState: .background
        )

        #expect(ChatComposerExecutionPresentation.shouldUseExecutionProjectionUI(for: projection))
    }

    @Test
    func backgroundRunningProjectionShowsStatusBadge() {
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            runningJobID: UUID(),
            activeProviderID: .builtInAgent,
            currentPhase: .executing,
            activityState: .running,
            presentationState: .background
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: true,
            projection: projection,
            canSend: true
        )

        #expect(presentation.showsRunningBadge)
        #expect(presentation.statusBadgeText == "后台运行")
    }

    @Test
    func blockedProjectionShowsAttentionStatusBadge() {
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            runningJobID: UUID(),
            canEditComposer: false,
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
            canSend: true
        )

        #expect(presentation.showsRunningBadge)
        #expect(presentation.statusBadgeText == "等待处理")
    }

    @Test
    func idleProjectionUsesProjectionStateWithoutLegacyFallback() {
        let projection = SessionExecutionProjection.fixture(
            sessionID: "session-a",
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent,
            activityState: .idle,
            presentationState: .foreground,
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: false,
            projection: projection,
            canSend: true
        )

        #expect(presentation.isComposerDisabled == false)
        #expect(presentation.showsRunningBadge == false)
        #expect(presentation.showsStopButton == false)
        #expect(presentation.showsSendButton)
        #expect(presentation.isSendDisabled == false)
    }
}