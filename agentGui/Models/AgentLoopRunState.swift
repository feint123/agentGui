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
    let hookState: AgentLoopBuiltInHookFactory.State
    var budgetRunTracker: BudgetRunTracker    // F-B1: per-run diminishing returns tracker

    init(
        runID: String = UUID().uuidString,
        accumulatedText: String = "",
        loopCtx: AgentLoopContext = AgentLoopContext(phase: .executing),
        loopMemory: ContextMemory = ContextMemory(),
        executionEvidence: Set<ExecutionEvidenceKind> = [],
        verificationState: VerificationState? = nil,
        hookState: AgentLoopBuiltInHookFactory.State = AgentLoopBuiltInHookFactory.State(),
        budgetRunTracker: BudgetRunTracker = BudgetRunTracker()   // F-B1
    ) {
        self.runID = runID
        self.accumulatedText = accumulatedText
        self.loopCtx = loopCtx
        self.loopMemory = loopMemory
        self.executionEvidence = executionEvidence
        self.verificationState = verificationState
        self.hookState = hookState
        self.budgetRunTracker = budgetRunTracker   // F-B1
    }
}