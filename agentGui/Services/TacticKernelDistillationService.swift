import Foundation

struct TacticKernelDistillationService {
    func distill(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let verifiedFacts = outcome.records.filter { $0.tags.contains("confirmed-fact") && $0.verificationStatus == .verified }
        guard verifiedFacts.isEmpty == false else { return [] }

        let summary = verifiedFacts.map(\.title).joined(separator: " | ")
        return [
            MemoryCandidate(
                id: "tactic-kernel-\(outcome.request.sessionId)",
                layer: .proceduralArchive,
                kind: .procedural,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Verified tactic kernel",
                summary: summary,
                payload: .text(summary),
                confidence: 0.82,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["tactic-kernel", "procedure"]
            )
        ]
    }
}