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
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: maxActiveProviders),
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

    // MARK: - claimBatch

    @Test
    func claimBatchReturnsEmptyWhenNoBriefedCards() throws {
        let state = makeState(maxActiveProviders: 2)
        // 把所有 briefed 卡设为 done
        guard var taskBoard = state.taskBoardState else {
            #expect(Bool(false), "Expected task board"); return
        }
        taskBoard.cards = taskBoard.cards.map {
            AgentTeamTaskCard(id: $0.id, title: $0.title, goal: $0.goal,
                              status: .done, owner: .builtIn, acceptedClaimID: UUID(),
                              dependencyIDs: $0.dependencyIDs, lastUpdatedAt: Date())
        }
        state.taskBoardState = taskBoard

        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)
        #expect(results.isEmpty)
    }

    @Test
    func claimBatchClaimsAllDispatchableBriefedCardsUpToBudget() throws {
        // Brief 中有 2 张独立 briefed 卡，maxActiveProviders=2
        let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 2)

        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        #expect(results.count == 2)
        // 两张卡都应进入 .claimed 状态
        let claimedCount = state.taskBoardState?.cards.filter { $0.status == .claimed }.count ?? 0
        #expect(claimedCount == 2)
    }

    @Test
    func claimBatchRespectsBudgetWhenAlreadyAtMax() throws {
        let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 1)

        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        // 只能认领 1 张（budget=1）
        #expect(results.count == 1)
    }

    @Test
    func claimBatchAssignsProvidersRoundRobin() throws {
        // eligibleProviders = [.builtIn, acp(X)]，2 张卡
        let acpID = UUID()
        let state = makeStateWithTwoIndependentBriefedCards(
            maxActiveProviders: 2,
            eligibleProviders: [.builtIn, .externalACP(profileID: acpID)]
        )

        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        #expect(results.count == 2)
        let providers = results.map { $0.executionTarget.providerReference }
        #expect(providers[0] == .builtIn)
        #expect(providers[1] == .externalACP(profileID: acpID))
    }

    @Test
    func claimBatchSetsStatusToActive() throws {
        let state = makeStateWithTwoIndependentBriefedCards(maxActiveProviders: 2)
        _ = try AgentTeamLaunchCoordinator().claimBatch(state: state)
        #expect(state.status == .active)
    }

    @Test
    func claimBatchThrowsMissingBriefWhenBriefAbsent() throws {
        let session = Session.fixture(title: "Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
        // no brief set

        #expect(throws: AgentTeamLaunchCoordinator.Error.missingBrief) {
            try AgentTeamLaunchCoordinator().claimBatch(state: state)
        }
    }

    @Test
    func claimBatchSkipsCardsWithUnresolvedDependencies() throws {
        // 1 张主卡（.briefed，no deps） + 1 张依赖主卡的子卡（.briefed）
        let state = makeState(maxActiveProviders: 2)
        // bootstrapBoard 会生成 1 主卡 + acceptance criteria 子卡（依赖主卡）
        // 只有主卡无依赖，子卡有依赖 → claimBatch 只认领主卡

        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        // 主卡 1 张可派发（子卡依赖主卡，未完成）
        #expect(results.count == 1)
        guard let primaryCard = state.taskBoardState?.cards.first(where: { $0.dependencyIDs.isEmpty }) else {
            #expect(Bool(false), "Expected primary card with no deps"); return
        }
        #expect(results[0].primaryCardID == primaryCard.id)
    }
}

// MARK: - Test helpers for Feature 8

@MainActor
private extension AgentTeamLaunchCoordinatorTests {
    func makeStateWithTwoIndependentBriefedCards(
        maxActiveProviders: Int = 2,
        eligibleProviders: [ExecutionProviderReference] = [.builtIn]
    ) -> AgentTeamSessionState {
        let cardA = UUID()
        let cardB = UUID()
        let session = Session.fixture(title: "Team (Parallel)", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .executionDelivery, status: .created)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "并行执行两个独立子任务",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: maxActiveProviders),
            initialContextSummary: "",
            providerPlan: .init(
                eligibleProviders: eligibleProviders,
                preferredConductor: eligibleProviders.first ?? .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
        // 手动构造两张独立 briefed 卡（无依赖）
        let board = AgentTeamTaskBoardState(
            cards: [
                AgentTeamTaskCard(id: cardA, title: "子任务 A", goal: "执行 A",
                                  status: .briefed, owner: nil, acceptedClaimID: nil,
                                  dependencyIDs: [], lastUpdatedAt: Date()),
                AgentTeamTaskCard(id: cardB, title: "子任务 B", goal: "执行 B",
                                  status: .briefed, owner: nil, acceptedClaimID: nil,
                                  dependencyIDs: [], lastUpdatedAt: Date())
            ],
            claims: []
        )
        state.taskBoardState = board
        state.claimBoardState = board.claimBoardProjection
        return state
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
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
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
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 1),
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

    @Test
    func artifactOverloadWithNoArtifactsMatchesBase() {
        let brief = AgentTeamMissionBrief(
            objective: "构建模块",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 1),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "主任务",
            goal: "完成目标",
            status: .briefed,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let builder = AgentTeamMissionPromptBuilder()
        let base = builder.buildPrompt(brief: brief, card: card)
        let withEmpty = builder.buildPrompt(brief: brief, card: card, artifacts: [])
        #expect(base == withEmpty)
    }

    @Test
    func artifactOverloadAppendsExistingArtifactsSection() {
        let brief = AgentTeamMissionBrief(
            objective: "构建模块",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 1),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "主任务",
            goal: "完成目标",
            status: .briefed,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let artifact = AgentTeamArtifact(
            id: UUID(),
            kind: .implementationPlan,
            title: "实现方案 v1",
            producer: .builtIn,
            taskCardID: UUID(),
            version: 1,
            summary: "初始方案摘要",
            payload: .text("content"),
            status: .draft
        )
        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card, artifacts: [artifact])
        #expect(prompt.contains("**Existing Artifacts:**"))
        #expect(prompt.contains("实现方案 v1"))
        #expect(prompt.contains("初始方案摘要"))
    }

    @Test
    func artifactOverloadListsMultipleArtifactsInOrder() {
        let brief = AgentTeamMissionBrief(
            objective: "测试目标",
            constraints: [],
            acceptanceCriteria: [],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 1),
            initialContextSummary: ""
        )
        let card = AgentTeamTaskCard(
            id: UUID(),
            title: "任务",
            goal: "完成",
            status: .briefed,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
        let a1 = AgentTeamArtifact(
            id: UUID(), kind: .brief, title: "摘要草稿",
            producer: .builtIn, taskCardID: UUID(), version: 1,
            summary: "第一个工件", payload: .text("t"), status: .draft
        )
        let a2 = AgentTeamArtifact(
            id: UUID(), kind: .validationReport, title: "验证报告",
            producer: .builtIn, taskCardID: UUID(), version: 1,
            summary: "第二个工件", payload: .text("t"), status: .submitted
        )
        let prompt = AgentTeamMissionPromptBuilder().buildPrompt(brief: brief, card: card, artifacts: [a1, a2])
        let range1 = prompt.range(of: "摘要草稿")!
        let range2 = prompt.range(of: "验证报告")!
        #expect(range1.lowerBound < range2.lowerBound)
    }
}
