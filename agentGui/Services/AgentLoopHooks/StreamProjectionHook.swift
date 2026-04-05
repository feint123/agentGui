import Foundation

struct StreamProjectionHook: AgentLoopHook {
    final class State {
        var lastProjectedTextLength = 0
        var lastProjectedThinkingLength = 0
    }

    let id = "stream-projection"
    let order = 10
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false
    let textThreshold: Int
    let thinkingThreshold: Int
    private let state: State

    init(
        state: State = State(),
        textThreshold: Int = 50,
        thinkingThreshold: Int = 50
    ) {
        self.state = state
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
    }

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        switch stage {
        case .didReceiveTextDelta, .didReceiveThinkingDelta:
            return true
        default:
            return false
        }
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        switch stage {
        case .didReceiveTextDelta:
            guard shouldProject(
                currentLength: context.currentRoundText.count,
                lastProjectedLength: state.lastProjectedTextLength,
                threshold: textThreshold,
                forceProjection: forceProjection(from: context)
            ) else {
                return .continue
            }

            state.lastProjectedTextLength = context.currentRoundText.count
            if let round = context.metadata["agentRound"] as? AgentRound {
                round.text = context.currentRoundText
            }

            switch context.streamProjectionTarget {
            case .none:
                break
            case .message(let message):
                message.textContent = context.accumulatedText
            case .workflowAction(let action):
                let snippet = context.accumulatedText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .last
                    .map(String.init) ?? ""
                if !snippet.isEmpty {
                    action(String(snippet.prefix(80)))
                }
            }

            // 通知 throttledSave：流式 delta 已写入，如果距上次 save 超过阈值则持久化。
            if let throttledSave = context.metadata["throttledSave"] as? StreamingThrottledSave {
                throttledSave.saveIfNeeded()
            }

        case .didReceiveThinkingDelta:
            guard shouldProject(
                currentLength: context.currentRoundThinking.count,
                lastProjectedLength: state.lastProjectedThinkingLength,
                threshold: thinkingThreshold,
                forceProjection: forceProjection(from: context)
            ) else {
                return .continue
            }

            state.lastProjectedThinkingLength = context.currentRoundThinking.count
            if let round = context.metadata["agentRound"] as? AgentRound {
                round.thinkingContent = context.currentRoundThinking
            }

        default:
            break
        }

        return .continue
    }

    private func forceProjection(from context: AgentLoopHookContext) -> Bool {
        context.metadata["forceProjection"] as? Bool ?? false
    }

    private func shouldProject(
        currentLength: Int,
        lastProjectedLength: Int,
        threshold: Int,
        forceProjection: Bool
    ) -> Bool {
        forceProjection || currentLength - lastProjectedLength >= threshold
    }
}