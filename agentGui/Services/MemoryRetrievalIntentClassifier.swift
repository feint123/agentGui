import Foundation

struct MemoryRetrievalIntentClassifier {
    // The classifier stays rule-based for now so retrieval remains explainable.
    func classify(
        request: MemoryRuntimeRequest,
        phaseHint: MemoryRetrievalPhase? = nil,
        epistemicState: EpistemicState = EpistemicState()
    ) -> MemoryRetrievalIntent {
        let stableState = epistemicState.stableSnapshot()
        let phase = phaseHint ?? inferredPhase(from: request.userRequest, epistemicState: stableState)
        return MemoryRetrievalIntent(
            phase: phase,
            neededObjectTypes: objectTypes(for: phase, taskKind: request.taskKind, epistemicState: stableState),
            reason: phaseHint == nil ? "derived from request and epistemic frontier" : "explicit phase hint"
        )
    }

    private func inferredPhase(from userRequest: String, epistemicState: EpistemicState) -> MemoryRetrievalPhase {
        if !epistemicState.frontiers.isEmpty || !epistemicState.counterexamples.isEmpty || !epistemicState.verificationDebt.isEmpty {
            return .frontierResolution
        }

        let lowercased = userRequest.lowercased()
        if lowercased.contains("verify") || lowercased.contains("test") || userRequest.contains("验证") || userRequest.contains("测试") {
            return .verification
        }
        if lowercased.contains("recover") || userRequest.contains("恢复") || userRequest.contains("排查") {
            return .recovery
        }
        if lowercased.contains("summary") || userRequest.contains("总结") {
            return .summarization
        }
        if lowercased.contains("fix") || userRequest.contains("修复") || userRequest.contains("修改") {
            return .modification
        }
        return .understanding
    }

    private func objectTypes(
        for phase: MemoryRetrievalPhase,
        taskKind: MemoryTaskKind,
        epistemicState: EpistemicState
    ) -> Set<MemoryRetrievalObjectType> {
        switch (taskKind, phase) {
        case (.coding, .frontierResolution):
            var types: Set<MemoryRetrievalObjectType> = [.fact, .procedure]
            if !epistemicState.counterexamples.isEmpty { types.insert(.counterexample) }
            if !epistemicState.activeConstraints.isEmpty || !epistemicState.frontiers.isEmpty { types.insert(.constraint) }
            if !epistemicState.verificationDebt.isEmpty { types.insert(.verificationDebt) }
            return types
        case (.coding, .verification):
            return [.fact, .procedure, .constraint]
        case (.coding, .recovery):
            return [.counterexample, .procedure, .fact]
        case (.coding, .modification):
            return [.fact, .constraint, .counterexample]
        case (.creativeWriting, _):
            return [.fact, .episode, .preference, .constraint]
        default:
            return [.fact, .preference, .constraint]
        }
    }
}