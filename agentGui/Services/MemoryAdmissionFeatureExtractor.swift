import Foundation

struct MemoryAdmissionFeatureExtractor {
    func extract(
        from candidate: MemoryCandidate,
        assessment: MemoryDecisionImpactAssessment
    ) -> MemoryAdmissionFeatureVector {
        MemoryAdmissionFeatureVector(
            decisionDelta: assessment.decisionDelta.value,
            transferability: assessment.transfer.value,
            evidenceStrength: assessment.evidence.value,
            decayResistance: assessment.decay.value,
            privacyRisk: candidate.scope == .user ? 0.2 : 0.0,
            confidenceSignal: min(max(candidate.confidence, 0), 1)
        )
    }
}