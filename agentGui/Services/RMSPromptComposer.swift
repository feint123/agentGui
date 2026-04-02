import Foundation

struct RMSPromptComposer {
    func compose(state: RMSState, activatedInsights: [RMSInsight]) -> String {
        let snapshot = state.stableSnapshot()

        let constraints = mergedConstraints(from: snapshot, insights: activatedInsights)
        let counterexamples = mergedCounterexamples(from: snapshot, insights: activatedInsights)
        let candidateActions = mergedCandidateActions(from: snapshot, insights: activatedInsights)

        let sections = [
            renderFrontiers(snapshot.frontiers),
            renderConstraints(constraints),
            renderCounterexamples(counterexamples),
            renderVerificationDebts(snapshot.verificationDebts),
            renderCandidateActions(candidateActions)
        ]

        return sections.joined(separator: "\n\n")
    }

    private func mergedConstraints(from state: RMSState, insights: [RMSInsight]) -> [String] {
        let stateItems = state.constraints.map(\.summary)
        let stateKeys = Set(stateItems.map { $0.lowercased() })
        let insightItems = insights
            .filter { $0.kind == .constraint }
            .compactMap { insight -> String? in
                guard !stateKeys.contains(insight.summary.lowercased()) else { return nil }
                return formattedInsightSummary(insight)
            }
        return unique(stateItems + insightItems)
    }

    private func mergedCounterexamples(from state: RMSState, insights: [RMSInsight]) -> [String] {
        let stateItems = state.counterexamples.map { "\($0.summary) -> \($0.replacementAction)" }
        let stateKeys = Set(state.counterexamples.map { "\($0.summary.lowercased())|\($0.replacementAction.lowercased())" })
        let insightItems = insights
            .filter { $0.kind == .counterexample }
            .compactMap { insight -> String? in
                let replacementAction = insight.replacementAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = "\(insight.summary.lowercased())|\(replacementAction.lowercased())"
                guard !stateKeys.contains(key) else { return nil }
                if !replacementAction.isEmpty {
                    return "\(formattedInsightSummary(insight)) -> \(replacementAction)"
                }
                return formattedInsightSummary(insight)
            }
        return unique(stateItems + insightItems)
    }

    private func mergedCandidateActions(from state: RMSState, insights: [RMSInsight]) -> [String] {
        let stateItems = state.candidateActions
        let stateKeys = Set(stateItems.map { $0.lowercased() })
        let insightItems = insights
            .filter { $0.kind == .tactic }
            .compactMap { insight -> String? in
                guard !stateKeys.contains(insight.summary.lowercased()) else { return nil }
                return formattedInsightSummary(insight)
            }
        return unique(stateItems + insightItems)
    }

    private func renderFrontiers(_ frontiers: [RMSFrontier]) -> String {
        let body = frontiers.isEmpty
            ? "- None"
            : frontiers.map { frontier in
                "- \(frontier.openClaim)\n  probe: \(frontier.suggestedProbe)\n  stop: \(frontier.stopCondition)"
            }.joined(separator: "\n")
        return "Current Frontiers\n\(body)"
    }

    private func renderConstraints(_ constraints: [String]) -> String {
        let body = constraints.isEmpty ? "- None" : constraints.map { "- \($0)" }.joined(separator: "\n")
        return "Constraints\n\(body)"
    }

    private func renderCounterexamples(_ counterexamples: [String]) -> String {
        let body = counterexamples.isEmpty ? "- None" : counterexamples.map { "- \($0)" }.joined(separator: "\n")
        return "Known Counterexamples\n\(body)"
    }

    private func renderVerificationDebts(_ debts: [RMSVerificationDebt]) -> String {
        let body = debts.isEmpty ? "- None" : debts.map { "- \($0.claim): \($0.reason)" }.joined(separator: "\n")
        return "Verification Debt\n\(body)"
    }

    private func renderCandidateActions(_ actions: [String]) -> String {
        let body = actions.isEmpty ? "- None" : actions.map { "- \($0)" }.joined(separator: "\n")
        return "Preferred Next Actions\n\(body)"
    }

    private func formattedInsightSummary(_ insight: RMSInsight) -> String {
        var base = insight.summary
        if !insight.evidenceRefs.isEmpty {
            base += " [evidence: \(insight.evidenceRefs.joined(separator: ", "))]"
        }
        if let updatedAt = insight.updatedAt {
            let note = MemoryFreshnessAnnotator().freshnessText(updatedAt: updatedAt)
            if !note.isEmpty {
                base += " — ⚠️ \(note)"
            }
        }
        return base
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}