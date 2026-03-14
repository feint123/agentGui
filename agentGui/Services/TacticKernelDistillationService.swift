import Foundation

struct TacticKernelDistillationService {
    func distill(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let verifiedFacts = outcome.records.filter { $0.tags.contains("confirmed-fact") && $0.verificationStatus == .verified }
        guard verifiedFacts.isEmpty == false else { return [] }

        let summary = verifiedFacts.map(\.title).joined(separator: " | ")
        let descriptor = TacticKernelDescriptor(
            applicablePrecondition: "Use when the active task matches \(outcome.request.userRequest) and direct evidence is available",
            preferredActionSequence: verifiedFacts.map(\.title).joined(separator: " -> "),
            failureSignals: outcome.records.filter { $0.verificationStatus == .failed }.map(\.summary).joined(separator: " | ").nonEmpty ?? "Repeated failure or contradictory tool output",
            verificationPath: "Run targeted verification after applying the tactic derived from: \(summary)",
            exitCondition: "Stop when the target verification passes or a counterexample invalidates the tactic"
        )
        return [
            MemoryCandidate(
                id: "tactic-kernel-\(outcome.request.sessionId)",
                layer: .proceduralArchive,
                kind: .procedural,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Verified tactic kernel",
                summary: summary,
                payload: .structured(descriptor.asPayloadFields()),
                confidence: 0.82,
                verificationStatus: .partial,
                sourceRefs: verifiedFacts.map { .init(kind: "memory-record", identifier: $0.id) },
                tags: ["tactic-kernel", "procedure"]
            )
        ]
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}