import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamLaunchCoordinatorTests {

    // MARK: - Helpers

    private func makeState(
        objective: String = "为 ACP team 汇总修复方案",
        maxActiveProviders: Int = 2,
        dispatchPolicy: AgentTeamDispatchPolicy = .autoClaim
    ) -> AgentTeamSessionState {
        let session = Session.fixture(title: "Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
        state.missionBrief = AgentTeamMissionBrief(
            objective: objective,
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: maxActiveProviders, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。",
            providerPlan: .init(
                eligibleProviders: [.builtIn],
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: dispatchPolicy
            )
        )
        let taskBoard = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: state.missionBrief!,
            preferredProvider: .builtIn
        )
        state.taskBoardState = taskBoard
        state.claimBoardState = taskBoard.claimBoardProjection
        return state
    }

    // MARK: - Launch success

    @Test
    func launchAutoClaimsPrimaryCardForConductor() throws {
        let state = makeState()
        let result = try AgentTeamLaunchCoordinator().launch(state: state)

        #expect(result.executionTarget.providerReference == .builtIn)
        #expect(result.executionTarget.teamContext.taskCardID != UUID())
        #expect(result.missionPrompt.contains("ACP team"))
    }

    @Test
    func launchSetsStatusToActive() throws {
        let state = makeState()
        _ = try AgentTeamLaunchCoordinator().launch(state: state)

        #expect(state.status == .active)
    }

    @Test
    func launchTransitionsPrimaryCardToWorking() throws {
        let state = makeState()
        let result = try AgentTeamLaunchCoordinator().launch(state: state)
        let cardID = result.executionTarget.teamContext.taskCardID

        let working = state.taskBoardState?.card(id: cardID)
        #expect(working?.status == .working)
    }

    @Test
    func launchCreatesAcceptedClaimAlignedWithExecutionTarget() throws {
        let state = makeState()
        let result = try AgentTeamLaunchCoordinator().launch(state: state)
        let claimID = result.executionTarget.teamContext.claimID
        let cardID = result.executionTarget.teamContext.taskCardID

        let accepted = state.taskBoardState?.acceptedClaim(for: cardID)
        #expect(accepted?.id == claimID)
        #expect(accepted?.providerReference == .builtIn)
        #expect(accepted?.status == .accepted)
    }

    @Test
    func launchSyncsClaimBoardStateWithTaskBoard() throws {
        let state = makeState()
        let result = try AgentTeamLaunchCoordinator().launch(state: state)
        let cardID = result.executionTarget.teamContext.taskCardID

        let claimBoardAccepted = state.claimBoardState?.acceptedClaim(for: cardID)
        #expect(claimBoardAccepted?.status == .accepted)
    }

    // MARK: - Budget enforcement

    @Test
    func launchFailsWhenBudgetExceeded() throws {
        let state = makeState(maxActiveProviders: 1)

        // Manually push the primary card to .working to simulate an active card
        guard var taskBoard = state.taskBoardState,
              let firstCardID = taskBoard.cards.first?.id else {
            #expect(Bool(false), "Expected a task card")
            return
        }
        taskBoard.cards[0] = AgentTeamTaskCard(
            id: firstCardID,
            title: taskBoard.cards[0].title,
            goal: taskBoard.cards[0].goal,
            status: .working,
            owner: .builtIn,
            acceptedClaimID: UUID(),
            dependencyIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date()
        )
        state.taskBoardState = taskBoard

        #expect(throws: AgentTeamLaunchCoordinator.Error.providerBudgetExceeded(max: 1, active: 1)) {
            try AgentTeamLaunchCoordinator().launch(state: state)
        }
    }

    // MARK: - Missing brief

    @Test
    func launchFailsWhenBriefIsMissing() throws {
        let session = Session.fixture(title: "Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)

        #expect(throws: AgentTeamLaunchCoordinator.Error.missingBrief) {
            try AgentTeamLaunchCoordinator().launch(state: state)
        }
    }

    // MARK: - No primary card

    @Test
    func launchFailsWhenAllCardsAreClaimed() throws {
        let state = makeState()

        // Move all briefed cards out of the .briefed state
        guard var taskBoard = state.taskBoardState else {
            #expect(Bool(false), "Expected task board")
            return
        }
        taskBoard.cards = taskBoard.cards.map { card in
            AgentTeamTaskCard(
                id: card.id,
                title: card.title,
                goal: card.goal,
                status: .done,
                owner: .builtIn,
                acceptedClaimID: nil,
                dependencyIDs: card.dependencyIDs,
                blockerSummary: nil,
                lastUpdatedAt: Date()
            )
        }
        state.taskBoardState = taskBoard

        #expect(throws: AgentTeamLaunchCoordinator.Error.noPrimaryCard) {
            try AgentTeamLaunchCoordinator().launch(state: state)
        }
    }

    // MARK: - Stop

    @Test
    func stopSetsStatusToFailed() {
        let state = makeState()
        state.status = .active
        AgentTeamLaunchCoordinator().stop(state: state)
        #expect(state.status == .failed)
    }

    // MARK: - Card completion

    @Test
    func markCardDoneTransitionsCardToDone() throws {
        let state = makeState()
        _ = try AgentTeamLaunchCoordinator().launch(state: state)

        guard let workingCard = state.taskBoardState?.cards.first(where: { $0.status == .working }) else {
            #expect(Bool(false), "Expected a working card after launch")
            return
        }

        try AgentTeamLaunchCoordinator().markCardDone(workingCard.id, in: state)

        let card = state.taskBoardState?.card(id: workingCard.id)
        #expect(card?.status == .done)
    }

    @Test
    func markingAllCardsDoneCompletesTeam() throws {
        let state = makeState()
        _ = try AgentTeamLaunchCoordinator().launch(state: state)
        #expect(state.status == .active)

        // Mark all working/claimed cards as done
        let coordinator = AgentTeamLaunchCoordinator()
        let activeIDs = state.taskBoardState?.cards
            .filter { $0.status == .working || $0.status == .claimed }
            .map(\.id) ?? []

        for id in activeIDs {
            try coordinator.markCardDone(id, in: state)
        }

        #expect(state.status == .completed)
    }
}

// MARK: - AgentTeamMissionPromptBuilderTests

struct AgentTeamMissionPromptBuilderTests {
    @Test
    func promptContainsObjectiveAndConstraints() {
        let brief = AgentTeamMissionBrief(
            objective: "修复 ACP claim gate",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "来源聊天包含日志。"
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "修复主路径",
            goal: "建立 claim gate",
            status: .briefed,
            owner: nil,
            acceptedClaimID: nil,
            dependencyIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card)

        #expect(prompt.contains("修复 ACP claim gate"))
        #expect(prompt.contains("仅修改 Swift 文件"))
        #expect(prompt.contains("tests 通过"))
        #expect(prompt.contains("来源聊天包含日志"))
    }

    @Test
    func promptOmitsTaskSectionWhenGoalMatchesObjective() {
        let objective = "同一个目标"
        let brief = AgentTeamMissionBrief(
            objective: objective,
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 1, tokenBudgetText: "10k", costBudgetText: "low"),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "主任务",
            goal: objective,
            status: .briefed,
            owner: nil,
            acceptedClaimID: nil,
            dependencyIDs: [],
            blockerSummary: nil,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card)

        #expect(prompt.contains("Your Task") == false)
    }
}
