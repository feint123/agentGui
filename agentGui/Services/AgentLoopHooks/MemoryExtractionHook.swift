import Foundation

/// 在 `willFinishRun`（主 agent 完整结束）时，fire-and-forget 启动记忆提取 subagent。
///
/// 设计约束：
/// - `.subagent` 执行上下文不触发（防递归）
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际提取通过注入的 `callback` 闭包执行（由 AgentLoopHookDependencyFactory 构建）
struct MemoryExtractionHook: AgentLoopHook {
    let id = "memory-extraction"
    let order = 90
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    /// Injected callback: runs the extraction subagent async. Captures coordinator + service.
    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRun else { return .continue }

        // 只对主 agent run 触发
        guard context.executionContext == .mainAgent else { return .continue }

        // Fire-and-forget：不等待提取完成，立即放行 main loop
        let capturedContext = context
        let capturedCallback = callback
        Task.detached(priority: .background) {
            await capturedCallback(capturedContext)
        }

        return .continue
    }
}
