import Foundation

struct MemoryRetrievalIntentClassifier {
    // The classifier stays rule-based for now so retrieval remains explainable.
    func classify(request: MemoryRuntimeRequest, phaseHint: MemoryRetrievalPhase? = nil) -> MemoryRetrievalIntent {
        let phase = phaseHint ?? inferredPhase(from: request.userRequest)
        return MemoryRetrievalIntent(
            phase: phase,
            neededObjectTypes: objectTypes(for: phase, taskKind: request.taskKind),
            reason: phaseHint == nil ? "derived from user request" : "explicit phase hint"
        )
    }

    private func inferredPhase(from userRequest: String) -> MemoryRetrievalPhase {
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

    private func objectTypes(for phase: MemoryRetrievalPhase, taskKind: MemoryTaskKind) -> Set<MemoryRetrievalObjectType> {
        switch (taskKind, phase) {
        case (.coding, .verification):
            return [.fact, .procedure, .episode]
        case (.coding, .recovery):
            return [.episode, .bridge, .procedure]
        case (.coding, .modification):
            return [.fact, .episode]
        case (.creativeWriting, _):
            return [.fact, .episode, .preference]
        default:
            return [.fact, .preference]
        }
    }
}