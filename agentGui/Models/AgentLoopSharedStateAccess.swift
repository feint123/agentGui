/// 对 ClaudeService 持有的跨 run / 跨 session 状态的显式访问口。
/// 执行器通过这里读写共享副作用，避免重新退回到隐式捕获 self 的耦合方式。
struct AgentLoopSharedStateAccess {
    let readVerification: (String) -> CompletionVerification?
    let writeVerification: (String, CompletionVerification) -> Void
    let readExecutionEvidence: (String) -> Set<ExecutionEvidenceKind>
    let writeExecutionEvidence: (String, Set<ExecutionEvidenceKind>) -> Void
    let readEpistemicInputs: (String) -> [EpistemicInputEnvelope]
    let writeEpistemicInputs: (String, [EpistemicInputEnvelope]) -> Void
    let setCurrentModelId: (String) -> Void
    let setCurrentInputTokens: (Int) -> Void
}