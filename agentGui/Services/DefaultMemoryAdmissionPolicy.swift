import Foundation

struct DefaultMemoryAdmissionPolicy: MemoryAdmissionPolicy {
    func evaluate(candidate: MemoryCandidate, features: MemoryAdmissionFeatureVector) -> MemoryGovernanceEvaluation {
        let verificationBoost = min(Double(features.verificationSupport) * 0.1, 0.1)
        let total = (
            (features.futureUtility * 0.2) +
            (features.factualConfidence * 0.25) +
            (features.novelty * 0.1) +
            (features.temporalRecency * 0.05) +
            (features.taskRelevance * 0.2) +
            verificationBoost -
            (features.privacyRisk * 0.05) -
            (features.driftRisk * 0.15)
        ).clamped(to: 0...1)

        let route = route(for: candidate, total: total)
        let explanation = MemoryAdmissionExplanation(
            score: MemoryAdmissionScore(total: total, route: route.scoreRoute),
            featureVector: features,
            reasons: reasons(for: candidate, route: route, total: total)
        )
        return MemoryGovernanceEvaluation(route: route, explanation: explanation)
    }

    private func route(for candidate: MemoryCandidate, total: Double) -> MemoryGovernanceDecision {
        if candidate.domainProfile == "coding-task",
           candidate.layer == .task,
           candidate.kind == .working,
           candidate.verificationStatus == .verified,
              total >= 0.75 {
            return .acceptHotPath
        }

        if candidate.domainProfile == "creative-writing",
           candidate.layer == .semantic,
           candidate.kind == .semantic,
           candidate.verificationStatus != .verified,
           total < 0.6 {
            return .needsUserConfirmation
        }

        if total >= 0.65 {
            return .acceptBackground
        }

        if total >= 0.45 {
            return .archiveOnly
        }

        return .reject
    }

    private func reasons(for candidate: MemoryCandidate, route: MemoryGovernanceDecision, total: Double) -> [String] {
        var reasons: [String] = []
        if candidate.verificationStatus == .verified {
            reasons.append("verified evidence available")
        }
        reasons.append("score=\(String(format: "%.2f", total))")
        reasons.append("route=\(route.rawValue)")
        return reasons
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}