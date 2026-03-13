import Foundation

struct MemoryAdmissionExplanation: Codable, Equatable, Sendable {
    var score: MemoryAdmissionScore
    var featureVector: MemoryAdmissionFeatureVector
    var reasons: [String]
}