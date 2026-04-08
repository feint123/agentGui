import Foundation

struct StreamProjectionHook: AgentLoopHook {
    final class State {
        var lastProjectedTextLength = 0
        var lastProjectedThinkingLength = 0
        /// 上次实际执行投影的时间，用于时间门控。
        var lastProjectionDate: Date = .distantPast
    }

    let id = "stream-projection"
    let order = 10
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false
    let textThreshold: Int
    let thinkingThreshold: Int
    /// 两次投影之间的最短间隔（秒）。默认 1/60 ≈ 16.7ms，与屏幕帧率对齐。
    let minInterval: TimeInterval
    private let state: State

    init(
        state: State = State(),
        textThreshold: Int = 50,
        thinkingThreshold: Int = 50,
        minInterval: TimeInterval = 1.0 / 60.0
    ) {
        self.state = state
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
        self.minInterval = minInterval
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
        let now = Date()
        switch stage {
        case .didReceiveTextDelta:
            guard shouldProject(
                currentLength: context.currentRoundText.count,
                lastProjectedLength: state.lastProjectedTextLength,
                threshold: textThreshold,
                forceProjection: forceProjection(from: context),
                now: now
            ) else {
                return .continue
            }

            state.lastProjectedTextLength = context.currentRoundText.count
            state.lastProjectionDate = now
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

        case .didReceiveThinkingDelta:
            guard shouldProject(
                currentLength: context.currentRoundThinking.count,
                lastProjectedLength: state.lastProjectedThinkingLength,
                threshold: thinkingThreshold,
                forceProjection: forceProjection(from: context),
                now: now
            ) else {
                return .continue
            }

            state.lastProjectedThinkingLength = context.currentRoundThinking.count
            state.lastProjectionDate = now
            if let round = context.metadata["agentRound"] as? AgentRound {
                round.thinkingContent = context.currentRoundThinking
            }

        default:
            break
        }

        return .continue
    }

    // MARK: - Testable

    /// 内部可测方法，暴露判断逻辑（避免 `private`）。
    func shouldProjectForTest(
        currentLength: Int,
        lastProjectedLength: Int,
        threshold: Int,
        forceProjection: Bool,
        now: Date
    ) -> Bool {
        shouldProject(
            currentLength: currentLength,
            lastProjectedLength: lastProjectedLength,
            threshold: threshold,
            forceProjection: forceProjection,
            now: now
        )
    }

    // MARK: - Private

    private func forceProjection(from context: AgentLoopHookContext) -> Bool {
        context.metadata["forceProjection"] as? Bool ?? false
    }

    private func shouldProject(
        currentLength: Int,
        lastProjectedLength: Int,
        threshold: Int,
        forceProjection: Bool,
        now: Date
    ) -> Bool {
        if forceProjection { return true }
        guard currentLength - lastProjectedLength >= threshold else { return false }
        return now.timeIntervalSince(state.lastProjectionDate) >= minInterval
    }
}