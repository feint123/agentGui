import Foundation

struct MemoryAdmissionFeatureVector: Codable, Equatable, Sendable {
    var decisionDelta: Double
    var transferability: Double
    var evidenceStrength: Double
    var decayResistance: Double
    var privacyRisk: Double
    var confidenceSignal: Double
}