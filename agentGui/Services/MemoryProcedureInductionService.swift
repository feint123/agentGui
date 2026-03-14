import Foundation

struct MemoryProcedureInductionService {
    func induce(from outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        let verifiedFacts = outcome.records.filter { $0.tags.contains("confirmed-fact") && $0.verificationStatus == .verified }
        guard verifiedFacts.isEmpty == false else { return [] }

        return [
            MemoryCandidate(
                id: "tactic-kernel-legacy-\(outcome.request.sessionId)",
                layer: .proceduralArchive,
                kind: .procedural,
                domainProfile: "coding-task",
                scope: .session(id: outcome.request.sessionId),
                title: "Build verification tactic kernel",
                summary: "Run the known-good build command, inspect the first failing artifact, then retry with the verified fix.",
                payload: .text("Run the known-good build command, inspect the first failing artifact, then retry with the verified fix."),
                confidence: 0.8,
                verificationStatus: .partial,
                sourceRefs: [],
                tags: ["tactic-kernel"]
            )
        ]
    }
}