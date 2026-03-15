import Foundation

struct RMSSelector {
    func select(for state: RMSState, insights: [RMSInsight], budget: Int) -> [RMSInsight] {
        guard budget > 0 else {
            return []
        }

        let stateText = stateSearchText(from: state)
        let stateKeywords = keywords(from: stateText)

        return insights
            .enumerated()
            .sorted { lhs, rhs in
                let leftRelevance = relevance(of: lhs.element, stateText: stateText, stateKeywords: stateKeywords)
                let rightRelevance = relevance(of: rhs.element, stateText: stateText, stateKeywords: stateKeywords)
                if leftRelevance != rightRelevance {
                    return leftRelevance < rightRelevance
                }
                let leftPriority = priority(for: lhs.element.kind)
                let rightPriority = priority(for: rhs.element.kind)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                if lhs.element.confidence != rhs.element.confidence {
                    return lhs.element.confidence > rhs.element.confidence
                }
                return lhs.offset < rhs.offset
            }
            .prefix(budget)
            .map(\.element)
    }

    private func relevance(of insight: RMSInsight, stateText: String, stateKeywords: Set<String>) -> Int {
        let appliesWhen = insight.appliesWhen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !appliesWhen.isEmpty else {
            return 1
        }
        if stateText.contains(appliesWhen) {
            return 0
        }

        let appliesWhenKeywords = keywords(from: appliesWhen)
        if !appliesWhenKeywords.isEmpty && !stateKeywords.isDisjoint(with: appliesWhenKeywords) {
            return 0
        }

        if matchesTaskDomain(appliesWhen: appliesWhen, stateKeywords: stateKeywords) {
            return 0
        }

        return 1
    }

    private func priority(for kind: RMSInsightKind) -> Int {
        switch kind {
        case .constraint:
            return 0
        case .counterexample:
            return 1
        case .tactic:
            return 2
        }
    }

    private func stateSearchText(from state: RMSState) -> String {
        let fragments = [
            state.summary,
            state.frontiers.map(\.openClaim).joined(separator: " "),
            state.candidateActions.joined(separator: " "),
            state.constraints.map(\.summary).joined(separator: " ")
        ]
        return fragments
            .joined(separator: " ")
            .lowercased()
    }

    private func keywords(from text: String) -> Set<String> {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let normalized = String(scalars)
        return Set(normalized.split(separator: " ").map(String.init).filter { $0.count >= 4 })
    }

    private func matchesTaskDomain(appliesWhen: String, stateKeywords: Set<String>) -> Bool {
        if appliesWhen.contains("coding") {
            return !stateKeywords.intersection(["build", "swift", "patch", "xcodebuild", "test", "repo"]).isEmpty
        }
        if appliesWhen.contains("creative") {
            return !stateKeywords.intersection(["chapter", "story", "outline", "character"]).isEmpty
        }
        return false
    }
}