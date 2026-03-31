import Foundation

/// Drives the Brief → Claim → Commit lifecycle for a Team session.
///
/// Responsibilities:
/// - Auto-claim the first briefed card for the preferred conductor.
/// - Enforce `maxActiveProviders` budget before dispatching.
/// - Transition `AgentTeamRunStatus` from `.created` → `.active`.
/// - Expose card-level completion/blocker transitions.
@MainActor
struct AgentTeamLaunchCoordinator {

    // MARK: - Error

    enum Error: LocalizedError, Equatable {
        case missingBrief
        case noPrimaryCard
        case providerBudgetExceeded(max: Int, active: Int)

        var errorDescription: String? {
            switch self {
            case .missingBrief:
                return "Team 会话缺少 mission brief，无法启动。"
            case .noPrimaryCard:
                return "Task board 中没有处于 Briefed 状态的 task card。"
            case let .providerBudgetExceeded(max, active):
                return "当前已有 \(active) 个活跃 card，超过最大并发限制 \(max)。"
            }
        }
    }

    // MARK: - Result

    struct LaunchResult: Equatable {
        let executionTarget: AgentTeamExecutionTarget
        let missionPrompt: String
    }

    // MARK: - Launch

    /// Creates an accepted claim for the conductor, transitions the first briefed
    /// card to `.working`, sets `state.status = .active`, and returns the
    /// execution target + generated mission prompt.
    func launch(state: AgentTeamSessionState) throws -> LaunchResult {
        guard let brief = state.missionBrief else {
            throw Error.missingBrief
        }

        let conductor = brief.providerPlan.preferredConductor
        let taskBoardCoordinator = AgentTeamTaskBoardCoordinator()
        let claimCoordinator = AgentTeamClaimCoordinator()

        // Bootstrap board if it hasn't been initialised yet
        var taskBoard = state.taskBoardState
            ?? taskBoardCoordinator.bootstrapBoard(from: brief, preferredProvider: conductor)

        // Enforce maxActiveProviders: only count cards actively in flight
        let activeCount = taskBoard.cards.filter { $0.status == .working }.count
        let maxActive = brief.budget.maxActiveProviders
        guard activeCount < maxActive else {
            throw Error.providerBudgetExceeded(max: maxActive, active: activeCount)
        }

        // Find the first card that is still waiting to be claimed
        guard let primaryCard = taskBoard.cards.first(where: { $0.status == .briefed }) else {
            throw Error.noPrimaryCard
        }

        // Create an auto-claim for the conductor (confidence 1.0)
        let claim = AgentTeamClaim(
            id: UUID(),
            providerReference: conductor,
            taskCardID: primaryCard.id,
            confidence: 1.0,
            rationaleSummary: "Conductor auto-claim on team launch.",
            requiredCapabilities: [],
            expectedArtifacts: [],
            estimatedCostSummary: brief.budget.costBudgetText,
            status: .pending,
            submittedAt: Date()
        )

        // Register claim in the task board's claims array
        taskBoard.claims.append(claim)

        // Accept the best claim — updates both the claim projection and task board
        let (_, claimedTaskBoard) = try claimCoordinator.acceptBestClaim(
            for: primaryCard.id,
            in: taskBoard.claimBoardProjection,
            preferredProvider: conductor,
            updating: taskBoard,
            taskBoardCoordinator: taskBoardCoordinator
        )

        // Advance card from .claimed → .working
        let workingTaskBoard = try taskBoardCoordinator.transitionCard(
            primaryCard.id,
            to: .working,
            in: claimedTaskBoard
        )

        // Persist updated boards and flip team status to active
        state.taskBoardState = workingTaskBoard
        state.claimBoardState = workingTaskBoard.claimBoardProjection
        state.status = .active

        guard let acceptedClaim = workingTaskBoard.acceptedClaim(for: primaryCard.id) else {
            throw Error.noPrimaryCard
        }

        let executionTarget = AgentTeamExecutionTarget(
            providerReference: conductor,
            teamContext: AgentTeamExecutionContext(
                taskCardID: primaryCard.id,
                claimID: acceptedClaim.id
            )
        )

        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: primaryCard)
        return LaunchResult(executionTarget: executionTarget, missionPrompt: prompt)
    }

    // MARK: - Stop

    /// Marks the team as failed and stops any further dispatch.
    func stop(state: AgentTeamSessionState) {
        state.status = .failed
    }

    // MARK: - Card Completion

    /// Marks a working card as done. Completes the team if no active cards remain.
    func markCardDone(_ cardID: UUID, in state: AgentTeamSessionState) throws {
        guard var taskBoard = state.taskBoardState else { return }
        taskBoard = try AgentTeamTaskBoardCoordinator().transitionCard(cardID, to: .done, in: taskBoard)
        state.taskBoardState = taskBoard
        state.claimBoardState = taskBoard.claimBoardProjection

        let hasActiveCards = taskBoard.cards.contains {
            $0.status == .working || $0.status == .claimed
        }
        if !hasActiveCards && state.status == .active {
            state.status = .completed
        }
    }

    /// Marks a card as blocked with a given reason.
    func markCardBlocked(_ cardID: UUID, reason: String, in state: AgentTeamSessionState) throws {
        guard var taskBoard = state.taskBoardState else { return }
        taskBoard = try AgentTeamTaskBoardCoordinator().transitionCard(
            cardID,
            to: .blocked,
            blockerSummary: reason,
            in: taskBoard
        )
        state.taskBoardState = taskBoard
        state.claimBoardState = taskBoard.claimBoardProjection
    }
}
