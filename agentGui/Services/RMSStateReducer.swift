import Foundation

struct RMSStateReducer {
    func reduce(existing: RMSState?, envelope: EpistemicInputEnvelope) -> RMSState? {
        var state = existing?.stableSnapshot() ?? RMSState(
            taskID: envelope.sessionID,
            sessionID: envelope.sessionID,
            threadID: envelope.sessionID,
            summary: ""
        )

        if state.summary.isEmpty {
            state.summary = envelope.userAgentMessages
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? ""
        }

        let proposedActions = envelope.events
            .filter { $0.kind == .actionProposed }
            .map(\.summary)
        state.candidateActions = uniqueStrings(state.candidateActions + proposedActions)

        let suggestedProbe = proposedActions.first
            ?? envelope.toolObservations.first
            ?? state.frontiers.first?.suggestedProbe
            ?? "Gather direct evidence"

        let raisedFrontiers = envelope.events
            .filter { $0.kind == .claimRaised }
            .enumerated()
            .map { index, event in
                RMSFrontier(
                    id: event.id.isEmpty ? "frontier-\(envelope.roundIndex)-\(index)" : event.id,
                    goal: state.summary,
                    openClaim: event.summary,
                    suggestedProbe: suggestedProbe,
                    stopCondition: "Claim resolved with direct evidence"
                )
            }
        state.frontiers = uniqueFrontiers(state.frontiers + raisedFrontiers)

        let declaredConstraints = envelope.events
            .filter { $0.kind == .constraintDeclared }
            .enumerated()
            .map { index, event in
                RMSConstraint(
                    id: event.id.isEmpty ? "constraint-\(envelope.roundIndex)-\(index)" : event.id,
                    summary: event.summary,
                    scope: .session(id: envelope.sessionID)
                )
            }
        state.constraints = uniqueConstraints(state.constraints + declaredConstraints)

        let derivedCounterexamples = envelope.events
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
                    replacementAction: proposedActions.first ?? "Inspect before editing"
                )
            }
        state.counterexamples = uniqueCounterexamples(state.counterexamples + derivedCounterexamples)

        let meaningful = !state.summary.isEmpty ||
            !state.frontiers.isEmpty ||
            !state.constraints.isEmpty ||
            !state.counterexamples.isEmpty ||
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
}