import Foundation
import Testing
@testable import agentGui

@MainActor
struct RemoteTurnDeliveryCoordinatorTests {

    @Test func deliveryCoordinatorThrottlesTextProjectionUntilThreshold() async {
        let recorder = ProjectionRecorderSession()
        let coordinator = RemoteTurnDeliveryCoordinator(textThreshold: 5, thinkingThreshold: 5) { _ in
            recorder
        }

        let handle = await coordinator.beginTurn(
            context: ChannelProjectionContext(channelKind: .feishu, externalConversationID: "chat-1")
        )

        await handle.receive(
            .textSnapshot(accumulatedText: "hey", currentRoundText: "hey", roundIndex: 0, isForced: false)
        )
        #expect(recorder.events.isEmpty)

        await handle.receive(
            .textSnapshot(accumulatedText: "hello", currentRoundText: "hello", roundIndex: 0, isForced: false)
        )

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first == .textSnapshot(accumulatedText: "hello", currentRoundText: "hello", roundIndex: 0, isForced: false))
    }

    @Test func deliveryCoordinatorForceFlushesPendingSnapshotOnFinish() async {
        let recorder = ProjectionRecorderSession()
        let coordinator = RemoteTurnDeliveryCoordinator(textThreshold: 50, thinkingThreshold: 50) { _ in
            recorder
        }

        let handle = await coordinator.beginTurn(
            context: ChannelProjectionContext(channelKind: .feishu, externalConversationID: "chat-1")
        )

        await handle.receive(
            .textSnapshot(accumulatedText: "done", currentRoundText: "done", roundIndex: 0, isForced: false)
        )
        #expect(recorder.events.isEmpty)

        await handle.finish(finalText: "done")

        #expect(recorder.events.count == 2)
        #expect(recorder.events[0] == .textSnapshot(accumulatedText: "done", currentRoundText: "done", roundIndex: 0, isForced: false))
        #expect(recorder.events[1] == .completed(finalText: "done"))
        #expect(recorder.closeCallCount == 1)
    }

    @Test func deliveryCoordinatorFallsBackToNoopWhenNoSessionIsAvailable() async {
        let coordinator = RemoteTurnDeliveryCoordinator(textThreshold: 5, thinkingThreshold: 5) { _ in
            nil
        }

        let handle = await coordinator.beginTurn(
            context: ChannelProjectionContext(channelKind: .feishu, externalConversationID: "chat-1")
        )

        await handle.receive(
            .textSnapshot(accumulatedText: "hello", currentRoundText: "hello", roundIndex: 0, isForced: true)
        )
        await handle.finish(finalText: "hello")
        await handle.fail(summary: "boom")
    }
}

@MainActor
private final class ProjectionRecorderSession: ChannelProjectionSession {
    private(set) var events: [AgentLoopProjectionEvent] = []
    private(set) var closeCallCount = 0

    func ingest(_ event: AgentLoopProjectionEvent) async throws {
        events.append(event)
    }

    func close() async {
        closeCallCount += 1
    }
}
