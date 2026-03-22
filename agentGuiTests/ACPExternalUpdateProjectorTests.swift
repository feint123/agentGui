import Testing
@testable import agentGui

@MainActor
struct ACPExternalUpdateProjectorTests {
    @Test func projectorBatchesAssistantAndThinkingDeltasUntilThreshold() {
        let projector = ACPExternalUpdateProjector(textThreshold: 5, thinkingThreshold: 4, toolOutputThreshold: 8)

        let firstEvents = projector.project(
            events: [
                .assistantTextDelta("he"),
                .thinkingDelta("12")
            ],
            sessionID: "session-1"
        )
        #expect(firstEvents.isEmpty)

        let secondEvents = projector.project(
            events: [
                .assistantTextDelta("llo"),
                .thinkingDelta("34")
            ],
            sessionID: "session-1"
        )

        #expect(secondEvents == [
            .assistantTextDelta("hello"),
            .thinkingDelta("1234")
        ])
    }

    @Test func projectorThrottlesToolOutputByToolCallID() {
        let projector = ACPExternalUpdateProjector(textThreshold: 5, thinkingThreshold: 5, toolOutputThreshold: 10)

        let firstPass = projector.project(
            events: [
                .toolCallStarted(id: "tool-1", kind: .execute, title: "run", filePath: nil),
                .toolCallUpdated(id: "tool-1", kind: .execute, title: "run", filePath: nil, status: .inProgress, rawOutput: "12345")
            ],
            sessionID: "session-1"
        )

        #expect(firstPass == [
            .toolCallStarted(id: "tool-1", kind: .execute, title: "run", filePath: nil)
        ])

        let secondPass = projector.project(
            events: [
                .toolCallUpdated(id: "tool-1", kind: .execute, title: "run", filePath: nil, status: .inProgress, rawOutput: "12345678901")
            ],
            sessionID: "session-1"
        )

        #expect(secondPass == [
            .toolCallUpdated(id: "tool-1", kind: .execute, title: "run", filePath: nil, status: .inProgress, rawOutput: "12345678901")
        ])
    }

    @Test func projectorFlushesPendingStateAtTurnBoundary() {
        let projector = ACPExternalUpdateProjector(textThreshold: 50, thinkingThreshold: 50, toolOutputThreshold: 50)

        _ = projector.project(
            events: [
                .assistantTextDelta("done"),
                .thinkingDelta("plan"),
                .toolCallUpdated(id: "tool-1", kind: .execute, title: "run", filePath: nil, status: .inProgress, rawOutput: "partial")
            ],
            sessionID: "session-1"
        )

        let flushed = projector.flush(sessionID: "session-1")

        #expect(flushed == [
            .assistantTextDelta("done"),
            .thinkingDelta("plan"),
            .toolCallUpdated(id: "tool-1", kind: .execute, title: "run", filePath: nil, status: .inProgress, rawOutput: "partial")
        ])
    }
}