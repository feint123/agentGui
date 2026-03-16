import Foundation
import SwiftAnthropic

struct AgentLoopPhaseOutcomeApplication {
    var projectedTextReset: String?
    var shouldResetVerificationState: Bool = false
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
        verificationEnabled: Bool = false,
        verificationResolution: VerificationGateResolution? = nil
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
                switch verificationResolution {
                case .clearToFinish:
                    break
                case .needsMoreEvidence(let openClaims, let suggestedProbe):
                    let claimLines = openClaims.map { "- \($0)" }.joined(separator: "\n")
                    let probeLine = suggestedProbe.map { "Suggested next step: \($0)" } ?? "Suggested next step: gather direct evidence before finishing."
                    let obligation = """
                    Before you finish, verification is still open:
                    \(claimLines)
                    \(probeLine)
                    """
                    messages.append(.init(role: .user, content: .text(obligation)))
                    loopContext.phase = .executing
                    outcome.shouldResetVerificationState = true
                case nil:
                    loopContext.phase = .executing
                }
            }

        default:
            _ = accumulatedText
        }

        return outcome
    }
}