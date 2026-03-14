import Foundation

struct DefaultMemoryAdmissionPolicy: MemoryAdmissionPolicy {
    func evaluate(
        candidate: MemoryCandidate,
        features: MemoryAdmissionFeatureVector,
        assessment: MemoryDecisionImpactAssessment
    ) -> MemoryGovernanceEvaluation {
        let total = (
            (features.decisionDelta * 0.35) +
            (features.transferability * 0.2) +
            (features.evidenceStrength * 0.25) +
            (features.decayResistance * 0.15) +
            (features.confidenceSignal * 0.1) -
            (features.privacyRisk * 0.05)
        ).clamped(to: 0...1)

        let route = route(for: candidate, total: total, assessment: assessment)
        let explanation = MemoryAdmissionExplanation(
            score: MemoryAdmissionScore(total: total, route: route.scoreRoute),
            featureVector: features,
            assessment: assessment,
            reasons: reasons(for: candidate, route: route, total: total, assessment: assessment)
        )
        return MemoryGovernanceEvaluation(route: route, explanation: explanation)
    }

    private func route(
        for candidate: MemoryCandidate,
        total: Double,
        assessment: MemoryDecisionImpactAssessment
    ) -> MemoryGovernanceDecision {
        if candidate.domainProfile == "creative-writing",
           candidate.layer == .semantic,
           candidate.kind == .semantic,
           candidate.verificationStatus != .verified,
           assessment.decisionDelta.passes {
            return .needsUserConfirmation
        }

        guard assessment.decisionDelta.passes else {
            return .reject
        }

        if candidate.domainProfile == "coding-task",
           candidate.layer == .task,
           candidate.kind == .working,
           candidate.verificationStatus == .verified,
           total >= 0.72,
           assessment.evidence.passes,
           assessment.decay.passes {
            return .acceptHotPath
        }

        if assessment.evidence.passes, total >= 0.62 {
            return .acceptBackground
        }

        if total >= 0.35 || assessment.decay.passes == false || assessment.decisionDelta.value >= 0.5 {
            return .archiveOnly
        }

        return .reject
    }

    private func reasons(
        for candidate: MemoryCandidate,
        route: MemoryGovernanceDecision,
        total: Double,
        assessment: MemoryDecisionImpactAssessment
    ) -> [String] {
        var reasons: [String] = []
        reasons.append("decision delta: \(assessment.decisionDelta.rationale)")
        reasons.append("transfer: \(assessment.transfer.rationale)")
        reasons.append("evidence: \(assessment.evidence.rationale)")
        reasons.append("decay: \(assessment.decay.rationale)")
        if candidate.verificationStatus == .verified { reasons.append("verified evidence available") }
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