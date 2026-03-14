import Foundation

struct MemoryExperienceDistillationService {
    func distill(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let failedAttempts = outcome.records.filter { $0.tags.contains("failed-attempt") || $0.verificationStatus == .failed }
        guard failedAttempts.count >= 2 else { return [] }

        let summary = failedAttempts.map(\.summary).filter { !$0.isEmpty }.joined(separator: " | ")
        let sessionScope = MemoryScope.session(id: outcome.request.sessionId)

        return [
            MemoryCandidate(
                id: "counterexample-legacy-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: sessionScope,
                title: "Avoid invalidated recovery path",
                summary: summary,
                payload: .text(summary),
                confidence: 0.8,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["counterexample", "invalidated-procedure"]
            )
        ]
    }
}