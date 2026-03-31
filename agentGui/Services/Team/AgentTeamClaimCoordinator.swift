import Foundation

struct AgentTeamClaimCoordinator {
    func bootstrapBoard(
        from brief: AgentTeamMissionBrief,
        preferredProvider: ExecutionProviderReference
    ) -> AgentTeamClaimBoardState {
        _ = preferredProvider

        let title = brief.acceptanceCriteria.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? "主任务认领"

        return AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: UUID(),
                    title: title,
                    goal: brief.objective,
                    phase: .claiming,
                    owner: nil,
                    claimIDs: []
                )
            ],
            claims: []
        )
    }

    func submitClaim(
        _ claim: AgentTeamClaim,
        into board: AgentTeamClaimBoardState
    ) -> AgentTeamClaimBoardState {
        guard let cardIndex = board.cards.firstIndex(where: { $0.id == claim.taskCardID }) else {
            return board
        }

        var nextBoard = board
        let replacedClaimIDs = Set(
            nextBoard.claims
                .filter { $0.taskCardID == claim.taskCardID && $0.providerReference == claim.providerReference }
                .map(\ .id)
        )

        nextBoard.claims.removeAll {
            $0.taskCardID == claim.taskCardID && $0.providerReference == claim.providerReference
        }
        nextBoard.claims.append(claim)

        nextBoard.cards[cardIndex].claimIDs.removeAll { replacedClaimIDs.contains($0) }
        nextBoard.cards[cardIndex].claimIDs.append(claim.id)
        return nextBoard
    }

    func acceptBestClaim(
        for taskCardID: UUID,
        in board: AgentTeamClaimBoardState,
        preferredProvider: ExecutionProviderReference
    ) -> AgentTeamClaimBoardState {
        guard let cardIndex = board.cards.firstIndex(where: { $0.id == taskCardID }) else {
            return board
        }

        if board.cards[cardIndex].owner != nil,
           board.acceptedClaim(for: taskCardID) != nil {
            return board
        }

        let candidateClaims = board.claims(for: taskCardID).filter {
            $0.taskCardID == taskCardID && ($0.status == .pending || $0.status == .accepted)
        }
        guard let acceptedClaim = candidateClaims.sorted(by: { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            let lhsIsPreferred = lhs.providerReference == preferredProvider
            let rhsIsPreferred = rhs.providerReference == preferredProvider
            if lhsIsPreferred != rhsIsPreferred {
                return lhsIsPreferred
            }
            return lhs.providerReference.persistedValue < rhs.providerReference.persistedValue
        }).first else {
            return board
        }

        var nextBoard = board
        nextBoard.cards[cardIndex].owner = acceptedClaim.providerReference
        nextBoard.cards[cardIndex].phase = .claimed
        nextBoard.claims = nextBoard.claims.map { existing in
            guard existing.taskCardID == taskCardID else {
                return existing
            }
            if existing.id == acceptedClaim.id {
                return AgentTeamClaim(
                    id: existing.id,
                    providerReference: existing.providerReference,
                    taskCardID: existing.taskCardID,
                    confidence: existing.confidence,
                    rationaleSummary: existing.rationaleSummary,
                    requiredCapabilities: existing.requiredCapabilities,
                    expectedArtifacts: existing.expectedArtifacts,
                    estimatedCostSummary: existing.estimatedCostSummary,
                    status: .accepted,
                    submittedAt: existing.submittedAt
                )
            }

            return AgentTeamClaim(
                id: existing.id,
                providerReference: existing.providerReference,
                taskCardID: existing.taskCardID,
                confidence: existing.confidence,
                rationaleSummary: existing.rationaleSummary,
                requiredCapabilities: existing.requiredCapabilities,
                expectedArtifacts: existing.expectedArtifacts,
                estimatedCostSummary: existing.estimatedCostSummary,
                status: .rejected,
                submittedAt: existing.submittedAt
            )
        }
        return nextBoard
    }

    func acceptBestClaim(
        for taskCardID: UUID,
        in board: AgentTeamClaimBoardState,
        preferredProvider: ExecutionProviderReference,
        updating taskBoard: AgentTeamTaskBoardState,
        taskBoardCoordinator: AgentTeamTaskBoardCoordinator = AgentTeamTaskBoardCoordinator()
    ) throws -> (claimBoard: AgentTeamClaimBoardState, taskBoard: AgentTeamTaskBoardState) {
        let resolvedClaimBoard = acceptBestClaim(
            for: taskCardID,
            in: board,
            preferredProvider: preferredProvider
        )

        var nextTaskBoard = taskBoard
        nextTaskBoard.claims = resolvedClaimBoard.claims
        nextTaskBoard = try taskBoardCoordinator.applyingAcceptedClaim(taskCardID: taskCardID, in: nextTaskBoard)

        return (resolvedClaimBoard, nextTaskBoard)
    }
}