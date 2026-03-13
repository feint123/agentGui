import Foundation

protocol MemoryAdmissionPolicy {
    func evaluate(candidate: MemoryCandidate, features: MemoryAdmissionFeatureVector) -> MemoryGovernanceEvaluation
}