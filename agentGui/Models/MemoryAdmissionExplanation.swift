import Foundation

struct MemoryAdmissionExplanation: Codable, Equatable, Sendable {
    var score: MemoryAdmissionScore
    var featureVector: MemoryAdmissionFeatureVector
    var assessment: MemoryDecisionImpactAssessment
    var reasons: [String]
}