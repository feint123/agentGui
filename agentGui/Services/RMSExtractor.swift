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
    func extract(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        generator: any RMSInsightGenerating
    ) async throws -> RMSExtractionResult
}

struct RMSExtractor: RMSExtracting {
    func extract(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        generator: any RMSInsightGenerating
    ) async throws -> RMSExtractionResult {
        let scope = MemoryScope.session(id: envelope.sessionID)
        let delta = try await stateDelta(existing: existing, envelope: envelope, generator: generator)
        var proposals: [RMSInsightProposal] = []

        for event in envelope.events where supportsInsightGeneration(event.kind) {
            let summary = trimmed(event.summary)
            guard !summary.isEmpty else { continue }
            if let insight = try await generator.generateOptionalInsight(
                id: event.id,
                content: summary,
                envelope: envelope,
                event: event,
                scope: scope,
                updatedAt: Date()
            ) {
                proposals.append(RMSInsightProposal(insight: insight))
            }
        }

        return RMSExtractionResult(
            delta: delta,
            proposals: deduplicated(proposals)
        )
    }

    private func stateDelta(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        generator: any RMSInsightGenerating
    ) async throws -> RMSStateDelta {
        if let generated = try await generator.generateStateDelta(
            existing: existing,
            envelope: envelope,
            updatedAt: Date()
        ) {
            return generated
        }

        return fallbackStateDelta(existing: existing, envelope: envelope)
    }

    private func fallbackStateDelta(existing: RMSState?, envelope: EpistemicInputEnvelope) -> RMSStateDelta {
        let existingSnapshot = existing?.stableSnapshot()
        let summary = existingSnapshot?.summary.isEmpty == false
            ? nil
            : firstNonEmpty(in: envelope.userAgentMessages)

        let candidateActions = uniqueStrings(
            envelope.events
                .filter { $0.kind == .actionProposed }
                .map(\.summary)
        )
        let suggestedProbe = candidateActions.first
            ?? firstNonEmpty(in: envelope.toolObservations)
            ?? existingSnapshot?.frontiers.first?.suggestedProbe
            ?? "Gather direct evidence"

        let frontiers = envelope.events
            .filter { $0.kind == .claimRaised }
            .enumerated()
            .map { index, event in
                RMSFrontier(
                    id: event.id.isEmpty ? "frontier-\(envelope.roundIndex)-\(index)" : event.id,
                    goal: summary ?? existingSnapshot?.summary ?? firstNonEmpty(in: envelope.userAgentMessages) ?? "",
                    openClaim: trimmed(event.summary),
                    suggestedProbe: suggestedProbe,
                    stopCondition: "Claim resolved with direct evidence"
                )
            }

        let constraints = envelope.events
            .filter { $0.kind == .constraintDeclared }
            .enumerated()
            .map { index, event in
                RMSConstraint(
                    id: event.id.isEmpty ? "constraint-\(envelope.roundIndex)-\(index)" : event.id,
                    summary: trimmed(event.summary),
                    scope: .session(id: envelope.sessionID)
                )
            }

        let counterexamples = envelope.events
            .filter { event in
                event.kind == .observationReceived && (
                    event.sourceRefs.contains("counterexample") ||
                    event.summary.localizedCaseInsensitiveContains("regress") ||
                    event.summary.localizedCaseInsensitiveContains("failed")
                )
            }
            .enumerated()
            .map { index, event in
                RMSCounterexample(
                    id: event.id.isEmpty ? "counterexample-\(envelope.roundIndex)-\(index)" : event.id,
                    summary: trimmed(event.summary),
                    replacementAction: candidateActions.first ?? "Inspect before editing"
                )
            }

        let verificationDebts = envelope.events
            .filter { $0.kind == .claimRaised }
            .enumerated()
            .map { index, event in
                RMSVerificationDebt(
                    id: event.id.isEmpty ? "verification-debt-\(envelope.roundIndex)-\(index)" : event.id,
                    claim: trimmed(event.summary),
                    reason: "No direct evidence yet"
                )
            }

        let stopSignals = uniqueStrings(
            envelope.events
                .filter { $0.kind == .claimResolved }
                .map(\.summary)
        )

        return RMSStateDelta(
            summary: summary,
            frontiers: frontiers,
            constraints: constraints,
            counterexamples: counterexamples,
            verificationDebts: verificationDebts,
            candidateActions: candidateActions,
            stopSignals: stopSignals
        )
    }

    private func supportsInsightGeneration(_ kind: AtomicEpistemicEventKind) -> Bool {
        switch kind {
        case .constraintDeclared, .actionProposed, .observationReceived:
            return true
        default:
            return false
        }
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

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = trimmed(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func firstNonEmpty(in values: [String]) -> String? {
        values.lazy
            .map(trimmed)
            .first { !$0.isEmpty }
    }
}