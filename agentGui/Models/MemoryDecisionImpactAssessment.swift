import Foundation

struct MemoryAdmissionGateResult: Codable, Equatable, Sendable {
    var passes: Bool
    var value: Double
    var rationale: String

    init(passes: Bool, value: Double, rationale: String) {
        self.passes = passes
        self.value = value
        self.rationale = rationale
    }
}

struct MemoryDecisionImpactAssessment: Codable, Equatable, Sendable {
    var decisionDelta: MemoryAdmissionGateResult
    var transfer: MemoryAdmissionGateResult
    var evidence: MemoryAdmissionGateResult
    var decay: MemoryAdmissionGateResult

    init(
        decisionDelta: MemoryAdmissionGateResult,
        transfer: MemoryAdmissionGateResult,
        evidence: MemoryAdmissionGateResult,
        decay: MemoryAdmissionGateResult
    ) {
        self.decisionDelta = decisionDelta
        self.transfer = transfer
        self.evidence = evidence
        self.decay = decay
    }
}