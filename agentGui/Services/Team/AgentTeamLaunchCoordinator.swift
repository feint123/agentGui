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

    /// Intermediate result from the first phase (claim) of a two-phase launch.
    struct ClaimPhaseResult: Equatable {
        let primaryCardID: UUID
        let executionTarget: AgentTeamExecutionTarget
        let missionPrompt: String
    }

    // MARK: - Two-Phase Launch

    /// Phase 1: Bootstrap the task board, create an auto-claim for the conductor,
    /// and advance the primary card to `.claimed`. Also sets `state.status = .active`.
    /// Persists board state so SwiftUI can render the Claimed column before execution starts.
    func claimPrimaryCard(state: AgentTeamSessionState) throws -> ClaimPhaseResult {
        guard let brief = state.missionBrief else {
            throw Error.missingBrief
        }

        let conductor = brief.providerPlan.preferredConductor
        let taskBoardCoordinator = AgentTeamTaskBoardCoordinator()
        let claimCoordinator = AgentTeamClaimCoordinator()

        var taskBoard = state.taskBoardState
            ?? taskBoardCoordinator.bootstrapBoard(from: brief, preferredProvider: conductor)

        let activeCount = taskBoard.cards.filter { $0.status == .working }.count
        let maxActive = brief.budget.maxActiveProviders
        guard activeCount < maxActive else {
            throw Error.providerBudgetExceeded(max: maxActive, active: activeCount)
        }

        guard let primaryCard = taskBoard.cards.first(where: { $0.status == .briefed }) else {
            throw Error.noPrimaryCard
        }

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
        taskBoard.claims.append(claim)

        let (_, claimedTaskBoard) = try claimCoordinator.acceptBestClaim(
            for: primaryCard.id,
            in: taskBoard.claimBoardProjection,
            preferredProvider: conductor,
            updating: taskBoard,
            taskBoardCoordinator: taskBoardCoordinator
        )

        // Only advance to .claimed here — NOT .working
        state.taskBoardState = claimedTaskBoard
        state.claimBoardState = claimedTaskBoard.claimBoardProjection
        state.status = .active

        guard let acceptedClaim = claimedTaskBoard.acceptedClaim(for: primaryCard.id) else {
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
        return ClaimPhaseResult(primaryCardID: primaryCard.id, executionTarget: executionTarget, missionPrompt: prompt)
    }

    /// Phase 2: Advance the primary card from `.claimed` to `.working`.
    /// Call this after persisting Phase 1 and yielding to SwiftUI at least once.
    func beginWorking(cardID: UUID, in state: AgentTeamSessionState) throws {
        guard var taskBoard = state.taskBoardState else { return }
        taskBoard = try AgentTeamTaskBoardCoordinator().transitionCard(cardID, to: .working, in: taskBoard)
        state.taskBoardState = taskBoard
        state.claimBoardState = taskBoard.claimBoardProjection
    }

    // MARK: - Legacy single-step launch (kept for tests)

    /// Creates an accepted claim for the conductor, transitions the first briefed
    /// card to `.working`, sets `state.status = .active`, and returns the
    /// execution target + generated mission prompt.
    func launch(state: AgentTeamSessionState) throws -> LaunchResult {
        let claimResult = try claimPrimaryCard(state: state)
        try beginWorking(cardID: claimResult.primaryCardID, in: state)
        return LaunchResult(executionTarget: claimResult.executionTarget, missionPrompt: claimResult.missionPrompt)
    }

    // MARK: - Stop

    /// Marks the team as failed and stops any further dispatch.
    func stop(state: AgentTeamSessionState) {
        state.status = .failed
    }

    // MARK: - Batch Claim

    /// Assigns a provider from `eligibleProviders` using round-robin by `cardIndex`.
    /// Falls back to `.builtIn` when the list is empty.
    func assignedProvider(
        at cardIndex: Int,
        eligibleProviders: [ExecutionProviderReference]
    ) -> ExecutionProviderReference {
        guard !eligibleProviders.isEmpty else { return .builtIn }
        return eligibleProviders[cardIndex % eligibleProviders.count]
    }

    /// Claims all dispatchable `.briefed` cards (no unresolved dependencies) up to
    /// `brief.budget.maxActiveProviders`, assigns providers via round-robin from
    /// `brief.providerPlan.eligibleProviders`, and advances each card to `.claimed`.
    ///
    /// Returns a `ClaimPhaseResult` per claimed card. Returns `[]` when no dispatchable
    /// cards remain (all done, all blocked, or budget exhausted).
    ///
    /// Call `beginWorking(cardID:in:)` for each result after persisting the claimed state.
    func claimBatch(state: AgentTeamSessionState) throws -> [ClaimPhaseResult] {
        guard let brief = state.missionBrief else {
            throw Error.missingBrief
        }

        let taskBoardCoordinator = AgentTeamTaskBoardCoordinator()
        let claimCoordinator = AgentTeamClaimCoordinator()
        let conductor = brief.providerPlan.preferredConductor
        let eligibleProviders = brief.providerPlan.eligibleProviders
        let maxActive = brief.budget.maxActiveProviders

        var taskBoard = state.taskBoardState
            ?? taskBoardCoordinator.bootstrapBoard(from: brief, preferredProvider: conductor)

        let dispatchable = taskBoard.dispatchableCards(upTo: maxActive)
        guard !dispatchable.isEmpty else {
            return []
        }

        var results: [ClaimPhaseResult] = []

        let draftCards = dispatchable.filter { $0.kind == .creativeDraft }
        let totalDrafts = draftCards.count

        for (index, card) in dispatchable.enumerated() {
            let providerRef: ExecutionProviderReference
            if card.kind == .synthesis {
                providerRef = conductor
            } else {
                providerRef = assignedProvider(at: index, eligibleProviders: eligibleProviders)
            }

            let claim = AgentTeamClaim(
                id: UUID(),
                providerReference: providerRef,
                taskCardID: card.id,
                confidence: 1.0,
                rationaleSummary: "Batch auto-claim for execution parallelism.",
                requiredCapabilities: [],
                expectedArtifacts: [],
                estimatedCostSummary: brief.budget.costBudgetText,
                status: .pending,
                submittedAt: Date()
            )
            taskBoard.claims.append(claim)

            let (_, updatedBoard) = try claimCoordinator.acceptBestClaim(
                for: card.id,
                in: taskBoard.claimBoardProjection,
                preferredProvider: providerRef,
                updating: taskBoard,
                taskBoardCoordinator: taskBoardCoordinator
            )
            taskBoard = updatedBoard

            guard let acceptedClaim = taskBoard.acceptedClaim(for: card.id) else { continue }

            let executionTarget = AgentTeamExecutionTarget(
                providerReference: providerRef,
                teamContext: AgentTeamExecutionContext(
                    taskCardID: card.id,
                    claimID: acceptedClaim.id
                )
            )

            let promptBuilder = AgentTeamMissionPromptBuilder()
            let prompt: String
            switch card.kind {
            case .creativeDraft:
                let draftIndex = draftCards.firstIndex(where: { $0.id == card.id }) ?? index
                prompt = promptBuilder.buildCreativeDraftPrompt(
                    brief: brief,
                    card: card,
                    draftIndex: draftIndex,
                    totalDrafts: max(totalDrafts, 1)
                )
            case .synthesis:
                let groupID = card.creativeGroupID
                let draftArtifacts = (state.artifactBoardState?.artifacts ?? [])
                    .filter { artifact in
                        guard let gid = groupID else { return false }
                        return state.taskBoardState?.card(id: artifact.taskCardID)?.creativeGroupID == gid
                    }
                    .filter { $0.kind == .ideaDraft }
                prompt = promptBuilder.buildSynthesisPrompt(
                    brief: brief,
                    synthesisCard: card,
                    draftArtifacts: draftArtifacts
                )
            case .standard:
                let existingArtifacts = (state.artifactBoardState?.artifacts ?? [])
                    .filter { $0.taskCardID == card.id }
                prompt = promptBuilder.buildPrompt(brief: brief, card: card, artifacts: existingArtifacts)
            }

            results.append(ClaimPhaseResult(
                primaryCardID: card.id,
                executionTarget: executionTarget,
                missionPrompt: prompt
            ))
        }

        state.taskBoardState = taskBoard
        state.claimBoardState = taskBoard.claimBoardProjection
        state.status = .active

        return results
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
