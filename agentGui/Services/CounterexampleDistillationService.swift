import Foundation

struct CounterexampleDistillationService {
    func distill(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let failedAttempts = outcome.records.filter { $0.tags.contains("failed-attempt") || $0.verificationStatus == .failed }
        guard failedAttempts.count >= 2 else { return [] }

        let repeatedFailure = Dictionary(grouping: failedAttempts, by: \ .summary)
            .sorted { $0.value.count > $1.value.count }
            .first

        let summary = repeatedFailure?.key.isEmpty == false
            ? repeatedFailure?.key ?? "Repeated failed approach"
            : failedAttempts.map(\.summary).first(where: { !$0.isEmpty }) ?? "Repeated failed approach"

        return [
            MemoryCandidate(
                id: "counterexample-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Avoid repeated failed path",
                summary: summary,
                payload: .text(summary),
                confidence: 0.8,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["counterexample", "failed-attempt"]
            )
        ]
    }
}