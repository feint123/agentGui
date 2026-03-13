import Foundation

struct MemoryExperienceDistillationService {
    func distill(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let failedAttempts = outcome.records.filter { $0.tags.contains("failed-attempt") || $0.verificationStatus == .failed }
        guard failedAttempts.count >= 2 else { return [] }

        let summary = failedAttempts.map(\.summary).filter { !$0.isEmpty }.joined(separator: " | ")
        let sessionScope = MemoryScope.session(id: outcome.request.sessionId)

        return [
            MemoryCandidate(
                id: "strategy-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: sessionScope,
                title: "Prefer verified recovery path",
                summary: summary,
                payload: .text(summary),
                confidence: 0.8,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["strategy-tip"]
            ),
            MemoryCandidate(
                id: "recovery-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: sessionScope,
                title: "Re-run with shared scheme",
                summary: "If xcodebuild cannot find a scheme, make the scheme shared before retrying.",
                payload: .text("If xcodebuild cannot find a scheme, make the scheme shared before retrying."),
                confidence: 0.85,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["recovery-tip"]
            )
        ]
    }
}