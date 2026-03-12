import Foundation

struct FinalizationGuardHook: AgentLoopHook {
    let id = "finalization-guard"
    let order = 60
    let kind: AgentLoopHookKind = .decisionMaker
    let isRequired = false

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .decideFinalization
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .decideFinalization,
              let requirement = context.metadata["executionRequirement"] as? ExecutionRequirement,
              let evidenceKinds = context.metadata["executionEvidenceKinds"] as? Set<ExecutionEvidenceKind>,
              let retryCount = context.metadata["retryCount"] as? Int else {
            return .continue
        }

        let decision = ExecutionGuard.resolveFinalization(
            requirement: requirement,
            evidenceKinds: evidenceKinds,
            retryCount: retryCount
        )

        switch decision {
        case .allow:
            return .decision(.finalization(.allow))
        case .requestExecution(let prompt):
            return .decision(.finalization(.retry(prompt: prompt)))
        case .fail(let reason):
            return .decision(.finalization(.fail(reason: reason)))
        }
    }
}