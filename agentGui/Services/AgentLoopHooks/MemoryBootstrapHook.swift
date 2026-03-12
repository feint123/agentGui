import Foundation

struct MemoryBootstrapHook: AgentLoopHook {
    let id = "memory-bootstrap"
    let order = 20
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    let loader: (AgentLoopHookContext) async throws -> AgentLoopMessagePatch?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .prepareRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .prepareRun else {
            return .continue
        }

        guard let patch = try await loader(context), !patch.insertions.isEmpty else {
            return .continue
        }
        return .messagePatch(patch)
    }
}