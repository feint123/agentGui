import Foundation

struct AgentTeamClaim: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let providerReference: ExecutionProviderReference
    let taskCardID: UUID
    let confidence: Double
    let rationaleSummary: String
    let requiredCapabilities: [String]
    let expectedArtifacts: [String]
    let estimatedCostSummary: String
    let status: AgentTeamClaimStatus
    let submittedAt: Date
}

enum AgentTeamClaimStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case rejected
    case released
}

enum AgentTeamClaimCardPhase: String, Codable, Equatable, Sendable {
    case claiming
    case claimed
}

struct AgentTeamClaimCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var phase: AgentTeamClaimCardPhase
    var owner: ExecutionProviderReference?
    var claimIDs: [UUID]
}

struct AgentTeamClaimBoardState: Codable, Equatable, Sendable {
    var cards: [AgentTeamClaimCard]
    var claims: [AgentTeamClaim]

    func card(id: UUID) -> AgentTeamClaimCard? {
        cards.first(where: { $0.id == id })
    }

    func claim(id: UUID) -> AgentTeamClaim? {
        claims.first(where: { $0.id == id })
    }

    func claims(for taskCardID: UUID) -> [AgentTeamClaim] {
        guard let card = card(id: taskCardID) else {
            return claims.filter { $0.taskCardID == taskCardID }
        }

        let registeredClaimIDs = Set(card.claimIDs)
        return claims.filter {
            $0.taskCardID == taskCardID && registeredClaimIDs.contains($0.id)
        }
    }

    func acceptedClaim(for taskCardID: UUID) -> AgentTeamClaim? {
        claims(for: taskCardID)
            .filter { $0.status == .accepted }
            .sorted { lhs, rhs in
                if lhs.submittedAt != rhs.submittedAt {
                    return lhs.submittedAt < rhs.submittedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    func executionContext(for providerReference: ExecutionProviderReference) -> AgentTeamExecutionContext? {
        let ownedContexts = cards.compactMap { card -> AgentTeamExecutionContext? in
            guard card.owner == providerReference,
                  let claim = acceptedClaim(for: card.id),
                  claim.providerReference == providerReference else {
                return nil
            }

            return AgentTeamExecutionContext(taskCardID: card.id, claimID: claim.id)
        }

        guard ownedContexts.count == 1 else {
            return nil
        }

        return ownedContexts.first
    }
}

struct AgentTeamExecutionContext: Codable, Equatable, Sendable {
    let taskCardID: UUID
    let claimID: UUID
}