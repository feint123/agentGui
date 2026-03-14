import Foundation

struct TacticKernelDescriptor: Codable, Equatable, Sendable {
    var applicablePrecondition: String
    var preferredActionSequence: String
    var failureSignals: String
    var verificationPath: String
    var exitCondition: String

    func asPayloadFields() -> [String: String] {
        [
            "applicable_precondition": applicablePrecondition,
            "preferred_action_sequence": preferredActionSequence,
            "failure_signals": failureSignals,
            "verification_path": verificationPath,
            "exit_condition": exitCondition
        ]
    }
}

struct MemoryInvalidationAnalysis: Equatable, Sendable {
    var invalidatedRecordIDs: [String]
    var generatedSignals: [MemoryCandidate]
    var reasonSummary: String
}