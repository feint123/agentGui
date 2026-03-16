import Foundation

struct AgentLoopHookDispatcher {
    let hooks: [any AgentLoopHook]

    init(hooks: [any AgentLoopHook]) {
        self.hooks = hooks.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.id < rhs.id
            }
            return lhs.order < rhs.order
        }
    }

    func dispatch(
        _ stage: AgentLoopHookStage,
        context: AgentLoopHookContext
    ) async throws -> AgentLoopHookDispatchResult {
        var result = AgentLoopHookDispatchResult()

        for hook in hooks where hook.supports(stage) {
            do {
                let hookResult = try await hook.perform(stage: stage, context: context)
                switch hookResult {
                case .continue:
                    break
                case .decision(let decision):
                    result.decisions.append(decision)
                case .messagePatch(let patch):
                    if result.messagePatch == nil {
                        result.messagePatch = patch
                    } else {
                        result.messagePatch?.insertions.append(contentsOf: patch.insertions)
                        patch.metadata.forEach { key, value in
                            result.messagePatch?.metadata[key] = value
                        }
                    }
                case .toolCallRecord(let record):
                    result.toolCallRecord = record
                case .failureTrigger(let trigger):
                    result.failureTrigger = trigger
                }
            } catch {
                result.failures.append(
                    AgentLoopHookFailure(
                        hookID: hook.id,
                        stage: stage,
                        message: String(describing: error)
                    )
                )

                if hook.isRequired && hook.kind != .observer {
                    result.abortReason = .requiredHookFailed(hookID: hook.id)
                    return result
                }
            }
        }

        return result
    }
}