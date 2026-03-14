import Foundation

enum EpistemicUncertaintyType: String, Codable, Equatable, Sendable {
    case factual
    case tooling
    case procedural
    case environmental
    case goal
    case unknown
}

enum EpistemicImpactLevel: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
    case critical
}

struct FrontierMemory: Codable, Equatable, Sendable, Identifiable {
    var id: String { frontierId }

    var frontierId: String
    var goal: String
    var openClaim: String
    var uncertaintyType: EpistemicUncertaintyType
    var impactLevel: EpistemicImpactLevel
    var suggestedProbe: String
    var stopCondition: String
}

struct ConstraintMemory: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var scope: MemoryScope
}

struct VerificationDebt: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var claim: String
    var reason: String
}

struct CounterexampleMemory: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var replacementAction: String
}

struct EpistemicState: Codable, Equatable, Sendable {
    var frontiers: [FrontierMemory] = []
    var activeConstraints: [ConstraintMemory] = []
    var candidateActions: [String] = []
    var verificationDebt: [VerificationDebt] = []
    var activatedMemories: [String] = []
    var counterexamples: [CounterexampleMemory] = []
    var residualRisk: Double = 0
    var expectedValueOfMoreReasoning: Double = 0

    init(
        frontiers: [FrontierMemory] = [],
        activeConstraints: [ConstraintMemory] = [],
        candidateActions: [String] = [],
        verificationDebt: [VerificationDebt] = [],
        activatedMemories: [String] = [],
        counterexamples: [CounterexampleMemory] = [],
        residualRisk: Double = 0,
        expectedValueOfMoreReasoning: Double = 0
    ) {
        self.frontiers = frontiers
        self.activeConstraints = activeConstraints
        self.candidateActions = candidateActions
        self.verificationDebt = verificationDebt
        self.activatedMemories = activatedMemories
        self.counterexamples = counterexamples
        self.residualRisk = residualRisk
        self.expectedValueOfMoreReasoning = expectedValueOfMoreReasoning
    }
}