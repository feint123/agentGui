import Testing
@testable import agentGui

@MainActor
struct SessionExecutionControllerTests {
    @Test
    func recordBlockedMarksSessionAsNeedingAttention() {
        let controller = SessionExecutionController(sessionID: "session-a")

        controller.recordBlocked(.userQuestion)

        #expect(controller.projection.activityState == .blocked)
        #expect(controller.projection.needsAttention)
        #expect(controller.projection.attentionReason == .userQuestion)
    }

    @Test
    func presentationStateCanMoveToBackgroundWithoutDroppingRunningState() {
        let controller = SessionExecutionController(sessionID: "session-a")

        controller.recordRunning(jobID: nil, providerID: .builtInAgent, currentPhase: .executing)
        controller.setPresentationState(.background)

        #expect(controller.projection.activityState == .running)
        #expect(controller.projection.presentationState == .background)
        #expect(controller.projection.isRunning)
    }
}