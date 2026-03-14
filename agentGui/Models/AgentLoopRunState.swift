import Foundation

/// 单次 agent loop 执行期间的可变状态。
/// 它只承载当前 run 的局部状态，不直接拥有 ClaudeService 上的共享 session 状态。
struct AgentLoopRunState {
    let runID: String
    var accumulatedText: String
    var loopCtx: AgentLoopContext
    var loopMemory: ContextMemory
    var executionEvidence: Set<ExecutionEvidenceKind>
    var verificationState: VerificationState?
    var epistemicState: EpistemicState
    var influenceTrace: MemoryInfluenceTrace
    let hookState: AgentLoopBuiltInHookFactory.State

    init(
        runID: String = UUID().uuidString,
        accumulatedText: String = "",
        loopCtx: AgentLoopContext = AgentLoopContext(phase: .executing),
        loopMemory: ContextMemory = ContextMemory(),
        executionEvidence: Set<ExecutionEvidenceKind> = [],
        verificationState: VerificationState? = nil,
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace(),
        hookState: AgentLoopBuiltInHookFactory.State = AgentLoopBuiltInHookFactory.State()
    ) {
        self.runID = runID
        self.accumulatedText = accumulatedText
        self.loopCtx = loopCtx
        self.loopMemory = loopMemory
        self.executionEvidence = executionEvidence
        self.verificationState = verificationState
        self.epistemicState = epistemicState.stableSnapshot()
        self.influenceTrace = influenceTrace
        self.hookState = hookState
    }
}