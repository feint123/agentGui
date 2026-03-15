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
    private let rawContentStore: any RMSRawContentStoring

    init(rawContentStore: any RMSRawContentStoring = RMSRawContentStore()) {
        self.rawContentStore = rawContentStore
    }

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
                var storedInsight = insight
                storedInsight.rawContentFilePath = try persistInsightRawContent(
                    for: event,
                    envelope: envelope,
                    insightID: insight.id
                )
                proposals.append(RMSInsightProposal(insight: storedInsight))
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
        if var generated = try await generator.generateStateDelta(
            existing: existing,
            envelope: envelope,
            updatedAt: Date()
        ) {
            generated.summarySourceFilePath = try persistDeltaRawContent(envelope: envelope)
            return generated
        }

        var fallback = fallbackStateDelta(existing: existing, envelope: envelope)
        fallback.summarySourceFilePath = try persistDeltaRawContent(envelope: envelope)
        return fallback
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

    private func persistInsightRawContent(
        for event: AtomicEpistemicEvent,
        envelope: EpistemicInputEnvelope,
        insightID: String
    ) throws -> String {
        let content = [
            "Event kind: \(event.kind.rawValue)",
            "Event summary:",
            event.summary,
            "",
            "Recent user/assistant messages:",
            envelope.userAgentMessages.isEmpty ? "- none" : envelope.userAgentMessages.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Tool observations:",
            envelope.toolObservations.isEmpty ? "- none" : envelope.toolObservations.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Source refs: \(event.sourceRefs.joined(separator: ", "))"
        ].joined(separator: "\n")
        return try rawContentStore.persistInsightRawContent(content, insightID: insightID)
    }

    private func persistDeltaRawContent(envelope: EpistemicInputEnvelope) throws -> String {
        let eventLines = envelope.events.map { event in
            let refs = event.sourceRefs.isEmpty ? "" : " [refs: \(event.sourceRefs.joined(separator: ", "))]"
            return "- \(event.kind.rawValue): \(event.summary)\(refs)"
        }
        let content = [
            "Session ID: \(envelope.sessionID)",
            "Round: \(envelope.roundIndex)",
            "",
            "User and assistant messages:",
            envelope.userAgentMessages.isEmpty ? "- none" : envelope.userAgentMessages.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Tool observations:",
            envelope.toolObservations.isEmpty ? "- none" : envelope.toolObservations.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Epistemic events:",
            eventLines.isEmpty ? "- none" : eventLines.joined(separator: "\n")
        ].joined(separator: "\n")
        return try rawContentStore.persistDeltaRawContent(content, sessionID: envelope.sessionID, roundIndex: envelope.roundIndex)
    }
}