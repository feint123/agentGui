import Foundation

/// 在 `willFinishRun`（主 agent 完整结束）时，fire-and-forget 启动记忆整合 subagent。
///
/// 设计约束与 `MemoryExtractionHook` 对齐：
/// - `.subagent` 执行上下文不触发（防递归）
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际整合通过注入的 `callback` 闭包执行（由 `AgentLoopHookDependencyFactory` 构建）
/// - order = 92：在 `MemoryExtractionHook`（order = 90）稍后执行，确保 extraction 先完成
struct MemoryConsolidationHook: AgentLoopHook {
    let id = "memory-consolidation"
    let order = 92
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRun else { return .continue }
        guard context.executionContext == .mainAgent else { return .continue }

        // Fire-and-forget：不等待整合完成，立即放行 main loop
        let capturedContext = context
        let capturedCallback = callback
        Task.detached(priority: .background) {
            await capturedCallback(capturedContext)
        }

        return .continue
    }
}
