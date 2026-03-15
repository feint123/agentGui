import Foundation

struct RMSExtractionResult: Equatable, Sendable {
    var delta: RMSStateDelta
    var proposals: [RMSInsightProposal]

    init(
        delta: RMSStateDelta = RMSStateDelta(),
        proposals: [RMSInsightProposal] = []
    ) {
        self.delta = delta
        self.proposals = proposals
    }
}

protocol RMSExtracting {
    func extract(existing: RMSState?, envelope: EpistemicInputEnvelope) -> RMSExtractionResult
}

struct RMSExtractor: RMSExtracting {
    func extract(existing: RMSState?, envelope: EpistemicInputEnvelope) -> RMSExtractionResult {
        let scope = MemoryScope.session(id: envelope.sessionID)
        let appliesWhen = extractionContext(existing: existing, envelope: envelope)
        let proposedActions = envelope.events
            .filter { $0.kind == .actionProposed }
            .map(\.summary)
            .map(trimmed)
            .filter { !$0.isEmpty }
        let replacementAction = proposedActions.first ?? "Inspect current state before acting"

        var proposals: [RMSInsightProposal] = []

        for event in envelope.events where event.kind == .constraintDeclared {
            let summary = trimmed(event.summary)
            guard !summary.isEmpty else { continue }
            proposals.append(
                RMSInsightProposal(
                    insight: RMSInsight.constraint(
                        id: event.id,
                        summary: summary,
                        appliesWhen: appliesWhen,
                        changesDecision: "apply the remembered constraint before taking the next action",
                        evidenceRefs: event.sourceRefs,
                        scope: scope,
                        confidence: 0.95
                    )
                )
            )
        }

        for event in envelope.events where event.kind == .actionProposed {
            let summary = trimmed(event.summary)
            guard !summary.isEmpty else { continue }
            proposals.append(
                RMSInsightProposal(
                    insight: RMSInsight.tactic(
                        id: event.id,
                        summary: summary,
                        appliesWhen: appliesWhen,
                        changesDecision: "prefer this tactic when the task matches the same problem shape",
                        evidenceRefs: event.sourceRefs,
                        scope: scope,
                        confidence: 0.8
                    )
                )
            )
        }

        for event in envelope.events where event.kind == .observationReceived {
            let summary = trimmed(event.summary)
            guard isCounterexample(summary: summary, sourceRefs: event.sourceRefs) else { continue }
            proposals.append(
                RMSInsightProposal(
                    insight: RMSInsight.counterexample(
                        id: event.id,
                        summary: summary,
                        appliesWhen: appliesWhen,
                        changesDecision: "avoid repeating the falsified path",
                        replacementAction: replacementAction,
                        evidenceRefs: event.sourceRefs,
                        scope: scope,
                        confidence: 0.9
                    )
                )
            )
        }

        return RMSExtractionResult(
            proposals: deduplicated(proposals)
        )
    }

    private func extractionContext(existing: RMSState?, envelope: EpistemicInputEnvelope) -> String {
        let candidates = [
            existing?.summary,
            envelope.userAgentMessages.first,
            envelope.toolObservations.first
        ]
        for candidate in candidates {
            let value = trimmed(candidate ?? "")
            if !value.isEmpty {
                return value
            }
        }
        return "general"
    }

    private func isCounterexample(summary: String, sourceRefs: [String]) -> Bool {
        guard !summary.isEmpty else { return false }
        if sourceRefs.contains("counterexample") {
            return true
        }

        let lowercased = summary.lowercased()
        return lowercased.contains("regress") ||
            lowercased.contains("failed") ||
            lowercased.contains("failure") ||
            lowercased.contains("avoid") ||
            lowercased.contains("broke")
    }

    private func deduplicated(_ proposals: [RMSInsightProposal]) -> [RMSInsightProposal] {
        var seen: Set<String> = []
        return proposals.filter { proposal in
            let key = [
                proposal.insight.kind.rawValue,
                trimmed(proposal.insight.summary),
                proposal.insight.scope?.namespace ?? "global"
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}