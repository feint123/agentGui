import Foundation

struct MemoryInvalidationService {
    func analyze(_ outcome: MemoryRuntimeOutcome) -> MemoryInvalidationAnalysis {
        let failedRecords = outcome.records.filter { $0.verificationStatus == .failed }
        let invalidatedRecordIDs = failedRecords.map(\.id)
        let generatedSignals = makeSignals(from: failedRecords, outcome: outcome)
        let reasonSummary = failedRecords.map(\.summary).filter { !$0.isEmpty }.joined(separator: " | ")

        return MemoryInvalidationAnalysis(
            invalidatedRecordIDs: invalidatedRecordIDs,
            generatedSignals: generatedSignals,
            reasonSummary: reasonSummary
        )
    }

    private func makeSignals(from failedRecords: [MemoryRecord], outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        guard failedRecords.isEmpty == false else { return [] }

        let summary = failedRecords.map(\.summary).first(where: { !$0.isEmpty }) ?? "Previously successful procedure is no longer reliable"
        let evidence = failedRecords.map(\.title).joined(separator: " | ")

        return [
            MemoryCandidate(
                id: "invalidated-procedure-\(outcome.request.sessionId)",
                layer: .task,
                kind: .working,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Invalidate failed procedure",
                summary: summary,
                payload: .structured([
                    "falsified_assumption": summary,
                    "contradicting_evidence": evidence,
                    "replacement_action": "Re-open verification and choose a different evidence-backed recovery path",
                    "context_fingerprint": "task=\(outcome.request.taskKind.rawValue) | request=\(outcome.request.userRequest)",
                    "failure_mode": "invalidated-procedure"
                ]),
                confidence: 0.7,
                verificationStatus: .partial,
                sourceRefs: failedRecords.map { .init(kind: "memory-record", identifier: $0.id) },
                tags: ["invalidated-procedure", "counterexample", "anti-pattern"]
            )
        ]
    }
}