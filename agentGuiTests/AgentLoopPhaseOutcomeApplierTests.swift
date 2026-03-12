import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct AgentLoopPhaseOutcomeApplierTests {

    @Test func applierBuildsContinuationPromptForMaxTokens() {
        var messages: [MessageParameter.Message] = []
        var loopContext = AgentLoopContext(phase: .continuingTruncatedResponse)
        let outcome = AgentLoopPhaseOutcomeApplier.apply(
            phase: .continuingTruncatedResponse,
            loopContext: &loopContext,
            messages: &messages,
            accumulatedText: "alpha",
            accumulatedTextBeforeRound: "alpha",
            currentRoundText: "beta",
            assistantObjects: []
        )

        let continuationPrompt = extractText(from: messages.last?.content)
        #expect(loopContext.phase == .executing)
        #expect(messages.count == 2)
        #expect(messages.first?.role == "assistant")
        #expect(messages.last?.role == "user")
        #expect(continuationPrompt.contains("Please continue your previous response exactly where you left off"))
        #expect(outcome.projectedTextReset == nil)
    }

    @Test func applierEntersReflectionOnlyWhenFailureTriggerExistsAndBudgetRemains() {
        var messages: [MessageParameter.Message] = []
        var loopContext = AgentLoopContext(phase: .finalizing)
        loopContext.pendingFailureTrigger = .toolFailure(toolName: "bash", errorText: "boom")
        let outcome = AgentLoopPhaseOutcomeApplier.apply(
            phase: .finalizing,
            loopContext: &loopContext,
            messages: &messages,
            accumulatedText: "current",
            accumulatedTextBeforeRound: "before",
            currentRoundText: "",
            assistantObjects: [],
            reflectionEnabled: true
        )

        #expect(loopContext.phase == .reflecting)
        #expect(outcome.projectedTextReset == nil)

        loopContext.phase = .finalizing
        loopContext.reflectionCount = 3
        _ = AgentLoopPhaseOutcomeApplier.apply(
            phase: .finalizing,
            loopContext: &loopContext,
            messages: &messages,
            accumulatedText: "current",
            accumulatedTextBeforeRound: "before",
            currentRoundText: "",
            assistantObjects: [],
            reflectionEnabled: true
        )

        #expect(loopContext.phase == .finalizing)
    }

    @Test func applierTransitionsIntoVerifyingBeforeAllowingCompletion() {
        var messages: [MessageParameter.Message] = []
        var loopContext = AgentLoopContext(phase: .finalizing)

        let outcome = AgentLoopPhaseOutcomeApplier.apply(
            phase: .finalizing,
            loopContext: &loopContext,
            messages: &messages,
            accumulatedText: "done",
            accumulatedTextBeforeRound: "done",
            currentRoundText: "",
            assistantObjects: [],
            reflectionEnabled: true,
            verificationEnabled: true
        )

        #expect(loopContext.phase == .verifying)
        #expect(outcome.projectedTextReset == nil)
    }
}

@MainActor
private func extractText(from content: MessageParameter.Message.Content?) -> String {
    guard let content else { return "" }
    return ClaudeService().extractText(from: content)
}