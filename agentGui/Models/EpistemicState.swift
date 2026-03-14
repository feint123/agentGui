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

extension EpistemicState {
    nonisolated func stableSnapshot() -> EpistemicState {
        let trim: (String) -> String = { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var snapshot = self
        snapshot.frontiers = frontiers.compactMap { frontier in
            let openClaim = trim(frontier.openClaim)
            guard !openClaim.isEmpty else {
                return nil
            }

            var normalized = frontier
            normalized.frontierId = trim(frontier.frontierId)
            normalized.goal = trim(frontier.goal)
            normalized.openClaim = openClaim
            normalized.suggestedProbe = trim(frontier.suggestedProbe)
            normalized.stopCondition = trim(frontier.stopCondition)
            return normalized
        }
        snapshot.activeConstraints = activeConstraints.compactMap { constraint in
            let summary = trim(constraint.summary)
            guard !summary.isEmpty else {
                return nil
            }

            var normalized = constraint
            normalized.id = trim(constraint.id)
            normalized.summary = summary
            return normalized
        }
        snapshot.candidateActions = candidateActions
            .map(trim)
            .filter { !$0.isEmpty }
        snapshot.verificationDebt = verificationDebt.compactMap { debt in
            let claim = trim(debt.claim)
            guard !claim.isEmpty else {
                return nil
            }

            var normalized = debt
            normalized.id = trim(debt.id)
            normalized.claim = claim
            normalized.reason = trim(debt.reason)
            return normalized
        }
        snapshot.activatedMemories = activatedMemories
            .map(trim)
            .filter { !$0.isEmpty }
        snapshot.counterexamples = counterexamples.compactMap { counterexample in
            let summary = trim(counterexample.summary)
            guard !summary.isEmpty else {
                return nil
            }

            var normalized = counterexample
            normalized.id = trim(counterexample.id)
            normalized.summary = summary
            normalized.replacementAction = trim(counterexample.replacementAction)
            return normalized
        }
        return snapshot
    }
}