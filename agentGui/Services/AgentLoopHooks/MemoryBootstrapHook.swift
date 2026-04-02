import Foundation

struct MemoryBootstrapHook: AgentLoopHook {
    let id = "memory-bootstrap"
    let order = 20
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    /// Loader 闭包：返回要追加到系统提示的 Memory 节文本，nil 表示跳过注入。
    let loader: (AgentLoopHookContext) async throws -> String?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .prepareRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .prepareRun else {
            return .continue
        }
        guard let section = try await loader(context), !section.isEmpty else {
            return .continue
        }
        return .systemPromptAppend(section)
    }
}