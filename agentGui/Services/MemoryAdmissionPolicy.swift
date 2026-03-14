import Foundation

protocol MemoryAdmissionPolicy {
    func evaluate(
        candidate: MemoryCandidate,
        features: MemoryAdmissionFeatureVector,
        assessment: MemoryDecisionImpactAssessment
    ) -> MemoryGovernanceEvaluation
}