import Foundation

struct RemoteChannelProjectionHook: AgentLoopHook {
    let id = "remote-channel-projection"
    let order = 15
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        switch stage {
        case .didReceiveTextDelta, .didReceiveThinkingDelta, .didFinishRun, .didFailRun:
            return true
        default:
            return false
        }
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard let remoteDeliveryHandle = context.remoteDeliveryHandle else {
            return .continue
        }

        switch stage {
        case .didReceiveTextDelta:
            await remoteDeliveryHandle.receive(
                .textSnapshot(
                    accumulatedText: context.accumulatedText,
                    currentRoundText: context.currentRoundText,
                    roundIndex: context.roundIndex,
                    isForced: forceProjection(from: context)
                )
            )

        case .didReceiveThinkingDelta:
            await remoteDeliveryHandle.receive(
                .thinkingSnapshot(
                    accumulatedThinking: context.currentRoundThinking,
                    roundIndex: context.roundIndex,
                    isForced: forceProjection(from: context)
                )
            )

        case .didFinishRun:
            await remoteDeliveryHandle.finish(finalText: context.accumulatedText)

        case .didFailRun:
            let summary = failureSummary(from: context)
            await remoteDeliveryHandle.fail(summary: summary)

        default:
            break
        }

        return .continue
    }

    private func forceProjection(from context: AgentLoopHookContext) -> Bool {
        context.metadata["forceProjection"] as? Bool ?? false
    }

    private func failureSummary(from context: AgentLoopHookContext) -> String {
        if let terminationReason = context.metadata["terminationReason"] as? String,
           !terminationReason.isEmpty,
           terminationReason != "completed" {
            return terminationReason
        }
        if !context.accumulatedText.isEmpty {
            return context.accumulatedText
        }
        return "remote channel delivery failed"
    }
}
