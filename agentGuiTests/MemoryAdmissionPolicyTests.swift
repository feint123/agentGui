import Foundation
import Testing
@testable import agentGui

struct MemoryAdmissionPolicyTests {
    @Test func admissionValueObjectsRoundTrip() throws {
        let anchor = MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild test")
        let assessment = MemoryDecisionImpactAssessment(
            decisionDelta: MemoryAdmissionGateResult(passes: true, value: 0.9, rationale: "changes verification order"),
            transfer: MemoryAdmissionGateResult(passes: true, value: 0.8, rationale: "reusable across coding tasks"),
            evidence: MemoryAdmissionGateResult(passes: true, value: 1.0, rationale: "backed by tool evidence"),
            decay: MemoryAdmissionGateResult(passes: true, value: 0.7, rationale: "stable across runs")
        )
        let featureVector = MemoryAdmissionFeatureVector(
            decisionDelta: 0.9,
            transferability: 0.8,
            evidenceStrength: 1.0,
            decayResistance: 0.7,
            privacyRisk: 0.0,
            confidenceSignal: 0.8
        )
        let score = MemoryAdmissionScore(total: 0.82, route: .hotPath)
        let explanation = MemoryAdmissionExplanation(
            score: score,
            featureVector: featureVector,
            assessment: assessment,
            reasons: ["verified tool evidence"]
        )

        #expect(explanation.reasons.contains("verified tool evidence"))
        #expect(score.route == .hotPath)
        #expect(anchor.kind == .toolCall)
        #expect(explanation.assessment.decisionDelta.passes)
    }
}