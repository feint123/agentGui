import Foundation
import Testing
@testable import agentGui

struct MemoryAdmissionPolicyTests {
    @Test func admissionValueObjectsRoundTrip() throws {
        let anchor = MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild test")
        let featureVector = MemoryAdmissionFeatureVector(
            futureUtility: 0.9,
            factualConfidence: 0.8,
            novelty: 0.7,
            temporalRecency: 0.6,
            taskRelevance: 0.95,
            verificationSupport: 1,
            privacyRisk: 0.0,
            driftRisk: 0.1
        )
        let score = MemoryAdmissionScore(total: 0.82, route: .hotPath)
        let explanation = MemoryAdmissionExplanation(
            score: score,
            featureVector: featureVector,
            reasons: ["verified tool evidence"]
        )

        #expect(explanation.reasons.contains("verified tool evidence"))
        #expect(score.route == .hotPath)
        #expect(anchor.kind == .toolCall)
    }
}