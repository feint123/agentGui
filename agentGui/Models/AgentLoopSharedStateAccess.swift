import SwiftAnthropic

/// 对 ClaudeService 持有的跨 run / 跨 session 状态的显式访问口。
/// 执行器通过这里读写共享副作用，避免重新退回到隐式捕获 self 的耦合方式。
struct AgentLoopSharedStateAccess {
    let readVerification: @MainActor (String) -> CompletionVerification?
    let writeVerification: @MainActor (String, CompletionVerification) -> Void
    let readExecutionEvidence: @MainActor (String) -> Set<ExecutionEvidenceKind>
    let writeExecutionEvidence: @MainActor (String, Set<ExecutionEvidenceKind>) -> Void
    let readEpistemicInputs: @MainActor (String) -> [EpistemicInputEnvelope]
    let writeEpistemicInputs: @MainActor (String, [EpistemicInputEnvelope]) -> Void
    let setCurrentModelId: @MainActor (String) -> Void
    let setCurrentInputTokens: @MainActor (Int) -> Void
    let updateContextBudget: @MainActor (ContextBudgetState) -> Void   // F-B1: context budget state
    // F-B3: 读取当前 session 的 context budget 状态（供 AgentLoopRunner 判断是否触发压缩）
    let readContextBudget: @MainActor () -> ContextBudgetState?
    // F-B3: 若 budget 状态满足触发条件，执行压缩并返回新消息数组；否则返回 nil
    let runCompactionIfNeeded: @MainActor ([MessageParameter.Message]) async -> [MessageParameter.Message]?
}