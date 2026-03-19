import Foundation
import Testing
@testable import agentGui

@MainActor
struct RemoteChannelProjectionHookTests {

    @Test func remoteChannelProjectionHookForwardsTextSnapshots() async throws {
        let recorder = RemoteDeliveryHandleRecorder()
        let hook = RemoteChannelProjectionHook()
        var context = AgentLoopHookContext.testRemoteProjectionContext()
        context.remoteDeliveryHandle = recorder
        context.accumulatedText = "hello"
        context.currentRoundText = "hello"
        context.metadata = ["forceProjection": true]

        _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(recorder.receivedEvents == [
            .textSnapshot(accumulatedText: "hello", currentRoundText: "hello", roundIndex: 0, isForced: true)
        ])
    }

    @Test func remoteChannelProjectionHookForwardsThinkingSnapshots() async throws {
        let recorder = RemoteDeliveryHandleRecorder()
        let hook = RemoteChannelProjectionHook()
        var context = AgentLoopHookContext.testRemoteProjectionContext()
        context.remoteDeliveryHandle = recorder
        context.currentRoundThinking = "thinking"

        _ = try await hook.perform(stage: .didReceiveThinkingDelta, context: context)

        #expect(recorder.receivedEvents == [
            .thinkingSnapshot(accumulatedThinking: "thinking", roundIndex: 0, isForced: false)
        ])
    }

    @Test func remoteChannelProjectionHookFinishesRunWithAccumulatedText() async throws {
        let recorder = RemoteDeliveryHandleRecorder()
        let hook = RemoteChannelProjectionHook()
        var context = AgentLoopHookContext.testRemoteProjectionContext()
        context.remoteDeliveryHandle = recorder
        context.accumulatedText = "final answer"

        _ = try await hook.perform(stage: .didFinishRun, context: context)

        #expect(recorder.finishedTexts == ["final answer"])
    }

    @Test func remoteChannelProjectionHookFailsRunWithTerminationReason() async throws {
        let recorder = RemoteDeliveryHandleRecorder()
        let hook = RemoteChannelProjectionHook()
        var context = AgentLoopHookContext.testRemoteProjectionContext()
        context.remoteDeliveryHandle = recorder
        context.metadata = ["terminationReason": "maxRounds"]

        _ = try await hook.perform(stage: .didFailRun, context: context)

        #expect(recorder.failureSummaries == ["maxRounds"])
    }
}

@MainActor
private final class RemoteDeliveryHandleRecorder: RemoteTurnDeliveryHandle {
    private(set) var receivedEvents: [AgentLoopProjectionEvent] = []
    private(set) var finishedTexts: [String] = []
    private(set) var failureSummaries: [String] = []

    func receive(_ event: AgentLoopProjectionEvent) async {
        receivedEvents.append(event)
    }

    func finish(finalText: String) async {
        finishedTexts.append(finalText)
    }

    func fail(summary: String) async {
        failureSummaries.append(summary)
    }
}

private extension AgentLoopHookContext {
    static func testRemoteProjectionContext() -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "executing"
        )
    }
}