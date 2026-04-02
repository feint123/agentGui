import Foundation

/// 在每个 `willFinishRound` 阶段检查 session memory 更新阈值。
///
/// 精确对齐 Claude Code `extractSessionMemory` postSamplingHook 的行为：
/// - 只对主 agent run（`.mainAgent` 执行上下文）触发
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际提取通过注入的 `callback` 闭包执行（fire-and-forget detached task）
/// - order = 85（在 MemoryExtractionHook(90) 之前）
struct SessionMemoryHook: AgentLoopHook {
    let id = "session-memory"
    let order = 85
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    /// Injected callback: 由 `SessionMemoryService.buildCallback()` 构建，
    /// 内部负责阈值检查和 subagent 更新逻辑。
    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRound
    }

    func perform(
        stage: AgentLoopHookStage,
        context: AgentLoopHookContext
    ) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRound else { return .continue }

        // 只对主 agent run 触发（对齐 Claude Code querySource === 'repl_main_thread' 守卫）
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
