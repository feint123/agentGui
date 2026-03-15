import Foundation

struct RMSStateReducer {
    func reduce(existing: RMSState?, envelope: EpistemicInputEnvelope) -> RMSState? {
        return reduce(
            existing: existing,
            delta: RMSExtractorStateDeltaAdapter.delta(from: envelope, existing: existing),
            sessionID: envelope.sessionID,
            threadID: envelope.sessionID,
            taskID: envelope.sessionID
        )
    }

    func reduce(existing: RMSState?, delta: RMSStateDelta, sessionID: String? = nil, threadID: String? = nil, taskID: String? = nil) -> RMSState? {
        var state = existing?.stableSnapshot() ?? RMSState(
            taskID: taskID ?? sessionID ?? "",
            sessionID: sessionID ?? existing?.sessionID ?? "",
            threadID: threadID ?? existing?.threadID ?? sessionID ?? "",
            summary: ""
        )

        if let summary = delta.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            state.summary = summary
        }

        state.frontiers = uniqueFrontiers(state.frontiers + delta.frontiers)
        state.constraints = uniqueConstraints(state.constraints + delta.constraints)
        state.counterexamples = uniqueCounterexamples(state.counterexamples + delta.counterexamples)
        state.verificationDebts = uniqueVerificationDebts(state.verificationDebts + delta.verificationDebts)
        state.candidateActions = uniqueStrings(state.candidateActions + delta.candidateActions)
        state.stopSignals = uniqueStrings(state.stopSignals + delta.stopSignals)
        state.updatedAt = Date()

        let meaningful = !state.summary.isEmpty ||
            !state.frontiers.isEmpty ||
            !state.constraints.isEmpty ||
            !state.counterexamples.isEmpty ||
            !state.verificationDebts.isEmpty ||
            !state.candidateActions.isEmpty
        return meaningful ? state.stableSnapshot() : nil
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    private func uniqueFrontiers(_ values: [RMSFrontier]) -> [RMSFrontier] {
        var seen: Set<String> = []
        return values.compactMap { frontier in
            let snapshot = RMSState(taskID: "", sessionID: "", threadID: "", summary: "", frontiers: [frontier]).stableSnapshot().frontiers.first
            guard let snapshot else { return nil }
            let key = snapshot.openClaim
            guard seen.insert(key).inserted else { return nil }
            return snapshot
        }
    }

    private func uniqueConstraints(_ values: [RMSConstraint]) -> [RMSConstraint] {
        var seen: Set<String> = []
        return values.compactMap { constraint in
            let trimmed = constraint.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return RMSConstraint(id: constraint.id, summary: trimmed, scope: constraint.scope)
        }
    }

    private func uniqueCounterexamples(_ values: [RMSCounterexample]) -> [RMSCounterexample] {
        var seen: Set<String> = []
        return values.compactMap { counterexample in
            let trimmed = counterexample.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return RMSCounterexample(
                id: counterexample.id,
                summary: trimmed,
                replacementAction: counterexample.replacementAction.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func uniqueVerificationDebts(_ values: [RMSVerificationDebt]) -> [RMSVerificationDebt] {
        var seen: Set<String> = []
        return values.compactMap { debt in
            let claim = debt.claim.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !claim.isEmpty, seen.insert(claim).inserted else { return nil }
            return RMSVerificationDebt(
                id: debt.id,
                claim: claim,
                reason: debt.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private enum RMSExtractorStateDeltaAdapter {
    static func delta(from envelope: EpistemicInputEnvelope, existing: RMSState?) -> RMSStateDelta {
        let existingSnapshot = existing?.stableSnapshot()
        let candidateActions = uniqueStrings(
            envelope.events
                .filter { $0.kind == .actionProposed }
                .map(\.summary)
        )
        let suggestedProbe = candidateActions.first
            ?? firstNonEmpty(in: envelope.toolObservations)
            ?? existingSnapshot?.frontiers.first?.suggestedProbe
            ?? "Gather direct evidence"
        let summary = existingSnapshot?.summary.isEmpty == false
            ? nil
            : firstNonEmpty(in: envelope.userAgentMessages)

        return RMSStateDelta(
            summary: summary,
            frontiers: envelope.events
                .filter { $0.kind == .claimRaised }
                .enumerated()
                .map { index, event in
                    RMSFrontier(
                        id: event.id.isEmpty ? "frontier-\(envelope.roundIndex)-\(index)" : event.id,
                        goal: summary ?? existingSnapshot?.summary ?? "",
                        openClaim: event.summary,
                        suggestedProbe: suggestedProbe,
                        stopCondition: "Claim resolved with direct evidence"
                    )
                },
            constraints: envelope.events
                .filter { $0.kind == .constraintDeclared }
                .enumerated()
                .map { index, event in
                    RMSConstraint(
                        id: event.id.isEmpty ? "constraint-\(envelope.roundIndex)-\(index)" : event.id,
                        summary: event.summary,
                        scope: .session(id: envelope.sessionID)
                    )
                },
            counterexamples: envelope.events
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
                        summary: event.summary,
                        replacementAction: candidateActions.first ?? "Inspect before editing"
                    )
                },
            verificationDebts: envelope.events
                .filter { $0.kind == .claimRaised }
                .enumerated()
                .map { index, event in
                    RMSVerificationDebt(
                        id: event.id.isEmpty ? "verification-debt-\(envelope.roundIndex)-\(index)" : event.id,
                        claim: event.summary,
                        reason: "No direct evidence yet"
                    )
                },
            candidateActions: candidateActions,
            stopSignals: uniqueStrings(
                envelope.events
                    .filter { $0.kind == .claimResolved }
                    .map(\.summary)
            )
        )
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func firstNonEmpty(in values: [String]) -> String? {
        values.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}