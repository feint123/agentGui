import Foundation

enum AgentTeamTaskStatus: String, Codable, Equatable, Sendable {
    case briefed
    case claimed
    case working
    case reviewing
    case done
    case blocked
}

struct AgentTeamTaskCard: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var goal: String
    var status: AgentTeamTaskStatus
    var owner: ExecutionProviderReference?
    var acceptedClaimID: UUID?
    var dependencyIDs: [UUID]
    var blockerSummary: String?
    var lastUpdatedAt: Date
}

struct AgentTeamTaskBoardState: Codable, Equatable, Sendable {
    var cards: [AgentTeamTaskCard]
    var claims: [AgentTeamClaim]

    var claimBoardProjection: AgentTeamClaimBoardState {
        AgentTeamClaimBoardState(
            cards: cards.map { card in
                let acceptedClaim = acceptedClaim(for: card.id)

                return AgentTeamClaimCard(
                    id: card.id,
                    title: card.title,
                    goal: card.goal,
                    phase: card.status.legacyClaimPhase,
                    owner: card.owner ?? acceptedClaim?.providerReference,
                    claimIDs: claims(for: card.id).map(\.id)
                )
            },
            claims: claims
        )
    }

    func card(id: UUID) -> AgentTeamTaskCard? {
        cards.first(where: { $0.id == id })
    }

    func claims(for taskCardID: UUID) -> [AgentTeamClaim] {
        claims.filter { $0.taskCardID == taskCardID }
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

    func unresolvedDependencies(for taskCardID: UUID) -> [UUID] {
        guard let taskCard = card(id: taskCardID) else {
            return []
        }

        return taskCard.dependencyIDs.filter { dependencyID in
            card(id: dependencyID)?.status != .done
        }
    }

    static func migrating(_ legacy: AgentTeamClaimBoardState) -> Self {
        Self(
            cards: legacy.cards.map { legacyCard in
                let acceptedClaim = legacy.acceptedClaim(for: legacyCard.id)

                return AgentTeamTaskCard(
                    id: legacyCard.id,
                    title: legacyCard.title,
                    goal: legacyCard.goal,
                    status: legacyCard.phase.taskStatus,
                    owner: legacyCard.owner,
                    acceptedClaimID: acceptedClaim?.id,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: acceptedClaim?.submittedAt ?? Date(timeIntervalSince1970: 0)
                )
            },
            claims: legacy.claims
        )
    }
}

private extension AgentTeamTaskStatus {
    var legacyClaimPhase: AgentTeamClaimCardPhase {
        switch self {
        case .briefed:
            return .claiming
        case .claimed, .working, .reviewing, .done, .blocked:
            return .claimed
        }
    }
}

private extension AgentTeamClaimCardPhase {
    var taskStatus: AgentTeamTaskStatus {
        switch self {
        case .claiming:
            return .briefed
        case .claimed:
            return .claimed
        }
    }
}