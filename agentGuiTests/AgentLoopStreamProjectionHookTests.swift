import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentLoopStreamProjectionHookTests {

    @Test func streamProjectionHookThrottlesTextProjectionUntilThreshold() async throws {
        let message = Message(direction: .agent, text: "")
        let round = AgentRound(roundIndex: 0)
        let hook = StreamProjectionHook(textThreshold: 5)

        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.streamProjectionTarget = .message(message)
        context.metadata = ["agentRound": round]
        context.currentRoundText = "hey"
        context.accumulatedText = "hey"

        _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(message.textContent == "")
        #expect(round.text == nil)

        context.currentRoundText = "hello"
        context.accumulatedText = "hello"

        _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(message.textContent == "hello")
        #expect(round.text == "hello")
    }

    @Test func streamProjectionHookForceFlushesBelowThreshold() async throws {
        let message = Message(direction: .agent, text: "")
        let round = AgentRound(roundIndex: 0)
        let hook = StreamProjectionHook(textThreshold: 50)

        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.streamProjectionTarget = .message(message)
        context.metadata = [
            "agentRound": round,
            "forceProjection": true
        ]
        context.currentRoundText = "done"
        context.accumulatedText = "done"

        _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(message.textContent == "done")
        #expect(round.text == "done")
    }

    @Test func streamProjectionHookThrottlesThinkingPersistenceUntilThreshold() async throws {
        let round = AgentRound(roundIndex: 0)
        let hook = StreamProjectionHook(thinkingThreshold: 5)

        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.metadata = ["agentRound": round]
        context.currentRoundThinking = "1234"

        _ = try await hook.perform(stage: .didReceiveThinkingDelta, context: context)

        #expect(round.thinkingContent == nil)

        context.currentRoundThinking = "12345"

        _ = try await hook.perform(stage: .didReceiveThinkingDelta, context: context)

        #expect(round.thinkingContent == "12345")
    }

    @Test func streamProjectionHookUpdatesAssistantMessageForMainAgent() async throws {
        let message = Message(direction: .agent, text: "")
        let hook = StreamProjectionHook()
        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.streamProjectionTarget = .message(message)
        context.metadata = ["forceProjection": true]
        context.currentRoundText = "hello"
        context.accumulatedText = "hello"

        let result = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(result == .continue)
        #expect(message.textContent == "hello")
    }

    @Test func streamProjectionHookSendsSnippetToWorkflowAction() async throws {
        let recorder = ActionRecorder()
        let hook = StreamProjectionHook()
        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.streamProjectionTarget = .workflowAction { recorder.capture($0) }
        context.metadata = ["forceProjection": true]
        context.accumulatedText = "line1\nworkflow summary line"
        context.currentRoundText = "workflow summary line"

        _ = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(recorder.values == ["workflow summary line"])
    }

    @Test func streamProjectionHookIgnoresSubagentProjection() async throws {
        let hook = StreamProjectionHook()
        var context = AgentLoopHookContext.testStreamProjectionContext()
        context.streamProjectionTarget = .none
        context.accumulatedText = "subagent output"

        let result = try await hook.perform(stage: .didReceiveTextDelta, context: context)

        #expect(result == .continue)
    }
}

@MainActor
private final class ActionRecorder {
    private(set) var values: [String] = []

    func capture(_ value: String) {
        values.append(value)
    }
}

private extension AgentLoopHookContext {
    static func testStreamProjectionContext() -> AgentLoopHookContext {
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