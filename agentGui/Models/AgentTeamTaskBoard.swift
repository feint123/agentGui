import Foundation

// MARK: - Task Card Kind

enum AgentTeamTaskCardKind: String, Codable, Equatable, Sendable {
    case standard
    case creativeDraft
    case synthesis
}

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
    var kind: AgentTeamTaskCardKind
    var creativeGroupID: UUID?
    var owner: ExecutionProviderReference?
    var acceptedClaimID: UUID?
    var dependencyIDs: [UUID]
    var artifactIDs: [UUID]
    var blockerSummary: String?
    var lastUpdatedAt: Date

    // MARK: - Memberwise init

    init(
        id: UUID,
        title: String,
        goal: String,
        status: AgentTeamTaskStatus,
        kind: AgentTeamTaskCardKind = .standard,
        creativeGroupID: UUID? = nil,
        owner: ExecutionProviderReference? = nil,
        acceptedClaimID: UUID? = nil,
        dependencyIDs: [UUID] = [],
        artifactIDs: [UUID] = [],
        blockerSummary: String? = nil,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.status = status
        self.kind = kind
        self.creativeGroupID = creativeGroupID
        self.owner = owner
        self.acceptedClaimID = acceptedClaimID
        self.dependencyIDs = dependencyIDs
        self.artifactIDs = artifactIDs
        self.blockerSummary = blockerSummary
        self.lastUpdatedAt = lastUpdatedAt
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, goal, status, kind, creativeGroupID, owner, acceptedClaimID
        case dependencyIDs, artifactIDs, blockerSummary, lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        title           = try c.decode(String.self, forKey: .title)
        goal            = try c.decode(String.self, forKey: .goal)
        status          = try c.decode(AgentTeamTaskStatus.self, forKey: .status)
        kind            = (try? c.decode(AgentTeamTaskCardKind.self, forKey: .kind)) ?? .standard
        creativeGroupID = try? c.decode(UUID.self, forKey: .creativeGroupID)
        owner           = try c.decodeIfPresent(ExecutionProviderReference.self, forKey: .owner)
        acceptedClaimID = try c.decodeIfPresent(UUID.self, forKey: .acceptedClaimID)
        dependencyIDs   = (try? c.decode([UUID].self, forKey: .dependencyIDs)) ?? []
        artifactIDs     = (try? c.decode([UUID].self, forKey: .artifactIDs)) ?? []
        blockerSummary  = try c.decodeIfPresent(String.self, forKey: .blockerSummary)
        lastUpdatedAt   = try c.decode(Date.self, forKey: .lastUpdatedAt)
    }
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

    /// Returns `.briefed` cards that have all dependencies resolved,
    /// limited to the remaining capacity given the current active count and `maxActiveProviders`.
    ///
    /// "Active" includes both `.working` and `.claimed` cards.
    func dispatchableCards(upTo maxActiveProviders: Int) -> [AgentTeamTaskCard] {
        let activeCount = cards.filter { $0.status == .working || $0.status == .claimed }.count
        let remaining = max(0, maxActiveProviders - activeCount)
        guard remaining > 0 else { return [] }
        return cards
            .filter { $0.status == .briefed }
            .filter { unresolvedDependencies(for: $0.id).isEmpty }
            .prefix(remaining)
            .map { $0 }
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
                    artifactIDs: [],
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