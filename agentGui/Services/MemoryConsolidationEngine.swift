import Foundation

struct MemoryConsolidationEngine {
    private let experienceDistiller: MemoryExperienceDistillationService
    private let procedureInductor: MemoryProcedureInductionService
    private let counterexampleDistiller: CounterexampleDistillationService
    private let tacticKernelDistiller: TacticKernelDistillationService

    init(
        experienceDistiller: MemoryExperienceDistillationService = MemoryExperienceDistillationService(),
        procedureInductor: MemoryProcedureInductionService = MemoryProcedureInductionService(),
        counterexampleDistiller: CounterexampleDistillationService = CounterexampleDistillationService(),
        tacticKernelDistiller: TacticKernelDistillationService = TacticKernelDistillationService()
    ) {
        self.experienceDistiller = experienceDistiller
        self.procedureInductor = procedureInductor
        self.counterexampleDistiller = counterexampleDistiller
        self.tacticKernelDistiller = tacticKernelDistiller
    }

    func consolidate(_ outcome: MemoryRuntimeOutcome) async throws -> [MemoryCandidate] {
        let request = outcome.request
        let profiles = MemoryDomainProfileRegistry().profiles(for: request)

        switch request.taskKind {
        case .coding:
            return consolidateCoding(outcome: outcome, profiles: profiles)
        case .creativeWriting:
            return consolidateCreative(outcome: outcome, profiles: profiles)
        case .generalAssistant:
            return consolidateGeneral(outcome: outcome)
        }
    }

    private func consolidateCoding(outcome: MemoryRuntimeOutcome, profiles: [MemoryDomainProfile]) -> [MemoryCandidate] {
        let rules = profiles.flatMap { $0.consolidationRules() }
        let factRule = rules.first(where: { $0.id == "coding-verified-fact" })
        let failureRule = rules.first(where: { $0.id == "coding-failure-chain" })
        let semanticRule = rules.first(where: { $0.id == "coding-stable-semantic-fact" })

        var candidates: [MemoryCandidate] = []
        let verifiedFacts = outcome.records.filter {
            [MemoryLayer.working, .task].contains($0.layer) &&
            $0.verificationStatus == .verified &&
            $0.confidence >= (factRule?.minimumConfidence ?? 0.0)
        }

        for record in verifiedFacts {
            candidates.append(record.asCandidate(targetLayer: factRule?.targetLayer ?? .task, targetKind: factRule?.targetKind ?? .working))
        }

        let failedAttempts = outcome.records.filter {
            $0.tags.contains("failed-attempt") || $0.verificationStatus == .failed
        }
        if failedAttempts.count >= 2 {
            let summary = failedAttempts.map(\.summary).joined(separator: " | ")
            candidates.append(
                MemoryCandidate(
                    id: "failure-chain-\(outcome.request.sessionId)",
                    layer: failureRule?.targetLayer ?? .episodic,
                    kind: failureRule?.targetKind ?? .episodic,
                    domainProfile: "coding-task",
                    scope: .session(id: outcome.request.sessionId),
                    title: "Failure chain",
                    summary: summary,
                    payload: .text(summary),
                    confidence: 0.85,
                    verificationStatus: .partial,
                    sourceRefs: [],
                    tags: ["failed-attempt", "failure-chain"]
                )
            )
        }

        let groupedByTitle = Dictionary(grouping: outcome.records.filter {
            ($0.layer == .task || $0.layer == .semantic) && $0.verificationStatus == .verified
        }, by: \.title)
        for (title, records) in groupedByTitle where records.count >= 2 {
            let first = records[0]
            if first.confidence >= (semanticRule?.minimumConfidence ?? 1.0) || records.allSatisfy({ $0.confidence >= 0.95 }) {
                candidates.append(first.asCandidate(targetLayer: semanticRule?.targetLayer ?? .semantic, targetKind: semanticRule?.targetKind ?? .semantic, title: title))
            }
        }

        let distilled = experienceDistiller.distill(from: outcome)
        let procedures = procedureInductor.induce(from: outcome)
        let counterexamples = counterexampleDistiller.distill(from: outcome)
        let tacticKernels = tacticKernelDistiller.distill(from: outcome)
        return deduplicated(candidates + distilled + procedures + counterexamples + tacticKernels)
    }

    private func consolidateCreative(outcome: MemoryRuntimeOutcome, profiles: [MemoryDomainProfile]) -> [MemoryCandidate] {
        let rules = profiles.flatMap { $0.consolidationRules() }
        let episodicRule = rules.first(where: { $0.id == "creative-episodic-events" })
        let semanticRule = rules.first(where: { $0.id == "creative-semantic-canon" })

        let episodicCandidates = outcome.records.filter {
            $0.layer == .episodic && $0.verificationStatus == .verified && $0.confidence >= (episodicRule?.minimumConfidence ?? 0.0)
        }.map {
            $0.asCandidate(targetLayer: episodicRule?.targetLayer ?? .episodic, targetKind: episodicRule?.targetKind ?? .episodic)
        }

        let semanticCandidates = outcome.records.filter {
            $0.layer == .semantic &&
            $0.verificationStatus == .verified &&
            $0.confidence >= (semanticRule?.minimumConfidence ?? 0.0)
        }.map {
            $0.asCandidate(targetLayer: semanticRule?.targetLayer ?? .semantic, targetKind: semanticRule?.targetKind ?? .semantic)
        }

        return deduplicated(episodicCandidates + semanticCandidates)
    }

    private func consolidateGeneral(outcome: MemoryRuntimeOutcome) -> [MemoryCandidate] {
        outcome.records.filter { $0.verificationStatus == .verified && $0.layer == .semantic }
            .map { $0.asCandidate(targetLayer: .semantic, targetKind: .semantic) }
    }

    private func deduplicated(_ candidates: [MemoryCandidate]) -> [MemoryCandidate] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let key = "\(candidate.layer.rawValue)-\(candidate.kind.rawValue)-\(candidate.title)"
            return seen.insert(key).inserted
        }
    }
}

private extension MemoryRecord {
    func asCandidate(targetLayer: MemoryLayer, targetKind: MemoryKind, title: String? = nil) -> MemoryCandidate {
        MemoryCandidate(
            id: id,
            layer: targetLayer,
            kind: targetKind,
            domainProfile: domainProfile,
            scope: scope,
            title: title ?? self.title,
            summary: summary,
            payload: payload,
            confidence: confidence,
            verificationStatus: verificationStatus,
            sourceRefs: sourceRefs,
            tags: tags
        )
    }
}