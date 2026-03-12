import Foundation
import SwiftAnthropic

struct AgentLoopPhaseOutcomeApplication {
    var projectedTextReset: String?
}

enum AgentLoopPhaseOutcomeApplier {
    static func apply(
        phase: AgentLoopPhase,
        loopContext: inout AgentLoopContext,
        messages: inout [MessageParameter.Message],
        accumulatedText: String,
        accumulatedTextBeforeRound: String,
        currentRoundText: String,
        assistantObjects: [MessageParameter.Message.Content.ContentObject],
        reflectionEnabled: Bool = false,
        verificationEnabled: Bool = false
    ) -> AgentLoopPhaseOutcomeApplication {
        var outcome = AgentLoopPhaseOutcomeApplication()

        switch phase {
        case .continuingTruncatedResponse:
            var resolvedAssistantObjects = assistantObjects
            if !currentRoundText.isEmpty {
                resolvedAssistantObjects.append(.text(currentRoundText))
            }
            if !resolvedAssistantObjects.isEmpty {
                messages.append(.init(role: .assistant, content: .list(resolvedAssistantObjects)))
            }
            messages.append(.init(
                role: .user,
                content: .text("Please continue your previous response exactly where you left off. Do not repeat what you already wrote and do not re-plan — just continue.")
            ))
            loopContext.continuationInjected()

        case .resumingAfterPause:
            var resolvedAssistantObjects = assistantObjects
            if !currentRoundText.isEmpty {
                resolvedAssistantObjects.append(.text(currentRoundText))
            }
            if !resolvedAssistantObjects.isEmpty {
                messages.append(.init(role: .assistant, content: .list(resolvedAssistantObjects)))
            }
            messages.append(.init(role: .user, content: .text("Continue.")))
            loopContext.continuationInjected()

        case .finalizing:
            if verificationEnabled {
                loopContext.phase = .verifying
            }

            if loopContext.phase == .finalizing,
               reflectionEnabled,
               loopContext.pendingFailureTrigger != nil,
               loopContext.reflectionCount < 3 {
                loopContext.phase = .reflecting
            }

        default:
            _ = accumulatedText
        }

        return outcome
    }
}