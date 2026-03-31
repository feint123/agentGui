import Foundation

struct AgentTeamTaskBoardCoordinator {
    enum Error: LocalizedError, Equatable {
        case cardNotFound(UUID)
        case acceptedClaimMissing(UUID)
        case unresolvedDependencies([UUID])
        case blockerSummaryRequired

        var errorDescription: String? {
            switch self {
            case let .cardNotFound(cardID):
                return "未找到 task card: \(cardID.uuidString.lowercased())。"
            case let .acceptedClaimMissing(cardID):
                return "task card \(cardID.uuidString.lowercased()) 缺少 accepted claim，无法进入 claimed/working 状态。"
            case let .unresolvedDependencies(dependencyIDs):
                let joined = dependencyIDs.map { $0.uuidString.lowercased() }.joined(separator: ", ")
                return "依赖尚未完成：\(joined)。"
            case .blockerSummaryRequired:
                return "进入 blocked 状态时必须提供 blockerSummary。"
            }
        }
    }

    func applyingAcceptedClaim(
        taskCardID: UUID,
        in board: AgentTeamTaskBoardState
    ) throws -> AgentTeamTaskBoardState {
        guard let acceptedClaim = board.acceptedClaim(for: taskCardID) else {
            throw Error.acceptedClaimMissing(taskCardID)
        }

        return try updateCard(taskCardID, in: board) { card in
            card.status = .claimed
            card.owner = acceptedClaim.providerReference
            card.acceptedClaimID = acceptedClaim.id
            card.blockerSummary = nil
            card.lastUpdatedAt = acceptedClaim.submittedAt
        }
    }

    func bootstrapBoard(
        from brief: AgentTeamMissionBrief,
        preferredProvider: ExecutionProviderReference
    ) -> AgentTeamTaskBoardState {
        _ = preferredProvider

        let primaryCardID = UUID()
        let primaryTitle = brief.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptanceCards = brief.acceptanceCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .prefix(3)
            .map { acceptance in
                AgentTeamTaskCard(
                    id: UUID(),
                    title: acceptance,
                    goal: acceptance,
                    status: .briefed,
                    owner: nil,
                    acceptedClaimID: nil,
                    dependencyIDs: [primaryCardID],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 0)
                )
            }

        return AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(
                    id: primaryCardID,
                    title: primaryTitle.isEmpty ? "主任务" : primaryTitle,
                    goal: brief.objective,
                    status: .briefed,
                    owner: nil,
                    acceptedClaimID: nil,
                    dependencyIDs: [],
                    blockerSummary: nil,
                    lastUpdatedAt: Date(timeIntervalSince1970: 0)
                )
            ] + acceptanceCards,
            claims: []
        )
    }

    func transitionCard(
        _ cardID: UUID,
        to status: AgentTeamTaskStatus,
        blockerSummary: String? = nil,
        in board: AgentTeamTaskBoardState
    ) throws -> AgentTeamTaskBoardState {
        switch status {
        case .claimed:
            return try transitionToClaimed(cardID, in: board)
        case .working:
            return try transitionToWorking(cardID, in: board)
        case .blocked:
            return try transitionToBlocked(cardID, blockerSummary: blockerSummary, in: board)
        case .briefed, .reviewing, .done:
            return try updateCard(cardID, in: board) { card in
                card.status = status
                card.blockerSummary = nil
                card.lastUpdatedAt = Date()
            }
        }
    }

    private func transitionToClaimed(_ cardID: UUID, in board: AgentTeamTaskBoardState) throws -> AgentTeamTaskBoardState {
        guard let acceptedClaim = board.acceptedClaim(for: cardID) else {
            throw Error.acceptedClaimMissing(cardID)
        }

        return try updateCard(cardID, in: board) { card in
            card.status = .claimed
            card.owner = acceptedClaim.providerReference
            card.acceptedClaimID = acceptedClaim.id
            card.blockerSummary = nil
            card.lastUpdatedAt = Date()
        }
    }

    private func transitionToWorking(_ cardID: UUID, in board: AgentTeamTaskBoardState) throws -> AgentTeamTaskBoardState {
        let unresolvedDependencies = board.unresolvedDependencies(for: cardID)
        guard unresolvedDependencies.isEmpty else {
            throw Error.unresolvedDependencies(unresolvedDependencies)
        }

        guard let card = board.card(id: cardID),
              card.acceptedClaimID != nil || board.acceptedClaim(for: cardID) != nil else {
            throw Error.acceptedClaimMissing(cardID)
        }

        return try updateCard(cardID, in: board) { nextCard in
            if nextCard.acceptedClaimID == nil,
               let acceptedClaim = board.acceptedClaim(for: cardID) {
                nextCard.acceptedClaimID = acceptedClaim.id
                nextCard.owner = acceptedClaim.providerReference
            }
            nextCard.status = .working
            nextCard.blockerSummary = nil
            nextCard.lastUpdatedAt = Date()
        }
    }

    private func transitionToBlocked(
        _ cardID: UUID,
        blockerSummary: String?,
        in board: AgentTeamTaskBoardState
    ) throws -> AgentTeamTaskBoardState {
        guard let blockerSummary, blockerSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Error.blockerSummaryRequired
        }

        return try updateCard(cardID, in: board) { card in
            card.status = .blocked
            card.blockerSummary = blockerSummary
            card.lastUpdatedAt = Date()
        }
    }

    private func updateCard(
        _ cardID: UUID,
        in board: AgentTeamTaskBoardState,
        mutate: (inout AgentTeamTaskCard) -> Void
    ) throws -> AgentTeamTaskBoardState {
        guard let cardIndex = board.cards.firstIndex(where: { $0.id == cardID }) else {
            throw Error.cardNotFound(cardID)
        }

        var nextBoard = board
        mutate(&nextBoard.cards[cardIndex])
        return nextBoard
    }
}