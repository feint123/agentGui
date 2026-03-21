import Foundation
import Testing
@testable import agentGui

struct ChatComposerExecutionPresentationTests {
    @Test func projectionRunningStateKeepsComposerEditableAndAllowsQueueing() {
        let projection = SessionExecutionProjection(
            sessionID: "session-1",
            runningJobID: UUID(),
            queuedJobIDs: [],
            queuedCount: 0,
            isRunning: true,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: true,
            projection: projection,
            legacyIsStreaming: false,
            canSend: true
        )

        #expect(presentation.isComposerDisabled == false)
        #expect(presentation.showsRunningBadge == true)
        #expect(presentation.queueBadgeText == nil)
        #expect(presentation.showsStopButton == true)
        #expect(presentation.showsSendButton == true)
        #expect(presentation.isSendDisabled == false)
    }

    @Test func projectionQueuedStateShowsQueueBadge() {
        let projection = SessionExecutionProjection(
            sessionID: "session-1",
            runningJobID: UUID(),
            queuedJobIDs: [UUID()],
            queuedCount: 1,
            isRunning: true,
            canEditComposer: true,
            canSubmitNewJob: true,
            activeProviderID: .builtInAgent
        )

        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: true,
            projection: projection,
            legacyIsStreaming: false,
            canSend: true
        )

        #expect(presentation.queueBadgeText == "队列 1")
    }

    @Test func legacyStreamingStateKeepsSendHiddenAndComposerLocked() {
        let presentation = ChatComposerExecutionPresentation.resolve(
            usesExecutionProjectionUI: false,
            projection: .empty(sessionID: "session-1"),
            legacyIsStreaming: true,
            canSend: true
        )

        #expect(presentation.isComposerDisabled == true)
        #expect(presentation.showsRunningBadge == false)
        #expect(presentation.queueBadgeText == nil)
        #expect(presentation.showsStopButton == true)
        #expect(presentation.showsSendButton == false)
    }
}