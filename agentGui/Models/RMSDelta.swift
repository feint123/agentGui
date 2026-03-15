import Foundation

struct RMSInsightProposal: Codable, Equatable, Sendable, Identifiable {
    var id: String { insight.id }
    var insight: RMSInsight
}

struct RMSStateDelta: Codable, Equatable, Sendable {
    var summary: String?
    var frontiers: [RMSFrontier]
    var constraints: [RMSConstraint]
    var counterexamples: [RMSCounterexample]
    var verificationDebts: [RMSVerificationDebt]
    var candidateActions: [String]
    var stopSignals: [String]

    init(
        summary: String? = nil,
        frontiers: [RMSFrontier] = [],
        constraints: [RMSConstraint] = [],
        counterexamples: [RMSCounterexample] = [],
        verificationDebts: [RMSVerificationDebt] = [],
        candidateActions: [String] = [],
        stopSignals: [String] = []
    ) {
        self.summary = summary
        self.frontiers = frontiers
        self.constraints = constraints
        self.counterexamples = counterexamples
        self.verificationDebts = verificationDebts
        self.candidateActions = candidateActions
        self.stopSignals = stopSignals
    }
}