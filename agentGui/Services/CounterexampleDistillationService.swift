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
        let evidence = failedAttempts.map(\.title).joined(separator: " | ")
        let replacementAction = inferredReplacementAction(from: summary, request: outcome.request.userRequest)
        let contextFingerprint = [
            "task=\(outcome.request.taskKind.rawValue)",
            "request=\(outcome.request.userRequest)",
            outcome.request.workspaceRoot.map { "workspace=\($0)" }
        ].compactMap { $0 }.joined(separator: " | ")
        let tags = ["counterexample", "anti-pattern"] + (shouldMarkInvalidatedProcedure(summary: summary) ? ["invalidated-procedure"] : [])

        return [
            MemoryCandidate(
                id: "counterexample-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Avoid repeated failed path",
                summary: summary,
                payload: .structured([
                    "falsified_assumption": summary,
                    "contradicting_evidence": evidence,
                    "replacement_action": replacementAction,
                    "context_fingerprint": contextFingerprint,
                    "failure_mode": "repeated-failure"
                ]),
                confidence: 0.8,
                verificationStatus: .partial,
                sourceRefs: failedAttempts.map { .init(kind: "memory-record", identifier: $0.id) },
                tags: tags
            )
        ]
    }

    private func inferredReplacementAction(from summary: String, request: String) -> String {
        let lowerSummary = summary.lowercased()
        if lowerSummary.contains("scheme") {
            return "Inspect and verify the shared scheme before editing project files"
        }
        if lowerSummary.contains("edit") {
            return "Inspect evidence and run verification before editing implementation"
        }
        if request.lowercased().contains("fix") {
            return "Gather direct evidence before retrying the previous recovery path"
        }
        return "Choose a different, evidence-backed next action"
    }

    private func shouldMarkInvalidatedProcedure(summary: String) -> Bool {
        let lowerSummary = summary.lowercased()
        return lowerSummary.contains("edit") || lowerSummary.contains("rerun") || lowerSummary.contains("before")
    }
}