import Foundation

struct MemoryAdmissionFeatureVector: Codable, Equatable, Sendable {
    var futureUtility: Double
    var factualConfidence: Double
    var novelty: Double
    var temporalRecency: Double
    var taskRelevance: Double
    var verificationSupport: Int
    var privacyRisk: Double
    var driftRisk: Double
}