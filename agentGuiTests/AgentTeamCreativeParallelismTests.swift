import Foundation
import Testing
@testable import agentGui

// MARK: - Task 1: AgentTeamTaskCardKind

struct AgentTeamTaskCardKindTests {

    @Test
    func standardCardDefaultsToStandardKindAfterJSONRoundTrip() throws {
        // 不写 kind 字段，验证 backward-compat 解码为 .standard
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "主任务",
          "goal": "执行修复",
          "status": "briefed",
          "dependencyIDs": [],
          "artifactIDs": [],
          "lastUpdatedAt": 0
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder().decode(AgentTeamTaskCard.self, from: json)

        #expect(card.kind == .standard)
        #expect(card.creativeGroupID == nil)
    }

    @Test
    func creativeDraftCardRoundTripsThroughJSON() throws {
        let groupID = UUID(uuidString: "60606060-6060-6060-6060-606060606060")!
        let card = AgentTeamTaskCard(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "草案 1",
            goal: "产出 ideaDraft",
            status: .briefed,
            kind: .creativeDraft,
            creativeGroupID: groupID,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.kind == .creativeDraft)
        #expect(decoded.creativeGroupID == groupID)
    }

    @Test
    func synthesisCardRoundTripsThroughJSON() throws {
        let groupID = UUID(uuidString: "70707070-7070-7070-7070-707070707070")!
        let draftID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let card = AgentTeamTaskCard(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "综合草案",
            goal: "产出 finalSynthesis",
            status: .briefed,
            kind: .synthesis,
            creativeGroupID: groupID,
            dependencyIDs: [draftID],
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(AgentTeamTaskCard.self, from: data)

        #expect(decoded.kind == .synthesis)
        #expect(decoded.creativeGroupID == groupID)
        #expect(decoded.dependencyIDs == [draftID])
    }
}

// MARK: - Task 2: bootstrapCreativeBoard

struct AgentTeamBootstrapCreativeBoardTests {

    // Stable test UUIDs for provider profile IDs
    static let copilotProfileID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    static let opencodeProfileID = UUID(uuidString: "0c0c0c0c-0c0c-0c0c-0c0c-0c0c0c0c0c0c")!
    static let qoderProfileID = UUID(uuidString: "aaaa0000-aaaa-0000-aaaa-aaaa0000aaaa")!

    private func makeBrief(
        objective: String = "生成创意方案",
        providers: [ExecutionProviderReference] = [.builtIn, .externalACP(profileID: Self.copilotProfileID)],
        maxActiveProviders: Int = 3
    ) -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: objective,
            constraints: ["风格统一"],
            acceptanceCriteria: ["产出 2 份草案"],
            mode: .creativeExploration,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: maxActiveProviders),
            initialContextSummary: "参考风格：极简主义",
            providerPlan: .init(
                eligibleProviders: providers,
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
    }

    @Test
    func bootstrapCreatesTwoDraftCardsPlusSynthesisForTwoProviders() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: Self.copilotProfileID)])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        let synthesisCards = board.cards.filter { $0.kind == .synthesis }

        #expect(draftCards.count == 2)
        #expect(synthesisCards.count == 1)
    }

    @Test
    func synthesisCardDependsOnAllDraftCards() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: Self.copilotProfileID)])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftIDs = Set(board.cards.filter { $0.kind == .creativeDraft }.map(\.id))
        let synthesisCard = board.cards.first { $0.kind == .synthesis }

        #expect(synthesisCard != nil)
        #expect(Set(synthesisCard!.dependencyIDs) == draftIDs)
    }

    @Test
    func allCardsShareSameCreativeGroupID() {
        let brief = makeBrief(providers: [.builtIn, .externalACP(profileID: Self.copilotProfileID)])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let groupIDs = Set(board.cards.compactMap(\.creativeGroupID))

        #expect(groupIDs.count == 1)   // 所有卡共享同一个 group ID
    }

    @Test
    func draftCardsAreAllBriefedWithNoDependencies() {
        let brief = makeBrief()
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        #expect(draftCards.allSatisfy { $0.status == .briefed })
        #expect(draftCards.allSatisfy { $0.dependencyIDs.isEmpty })
    }

    @Test
    func synthesisCardIsBriefedWithDependencies() {
        let brief = makeBrief()
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let synthesisCard = board.cards.first { $0.kind == .synthesis }

        #expect(synthesisCard?.status == .briefed)
        #expect(synthesisCard?.dependencyIDs.isEmpty == false)
    }

    @Test
    func draftCountCappedAtThreeEvenWithMoreProviders() {
        // 4 providers → 仍只生成 3 张 draft + 1 张 synthesis
        let providers: [ExecutionProviderReference] = [
            .builtIn,
            .externalACP(profileID: Self.copilotProfileID),
            .externalACP(profileID: Self.opencodeProfileID),
            .externalACP(profileID: Self.qoderProfileID)
        ]
        let brief = makeBrief(providers: providers, maxActiveProviders: 10)
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        #expect(draftCards.count == 3)
    }

    @Test
    func singleProviderCreatesOneDraftPlusSynthesis() {
        let brief = makeBrief(providers: [.builtIn])
        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let draftCards = board.cards.filter { $0.kind == .creativeDraft }
        let synthesisCards = board.cards.filter { $0.kind == .synthesis }

        #expect(draftCards.count == 1)
        #expect(synthesisCards.count == 1)
    }

    @Test
    func executionDeliveryModeProducesStandardCards() {
        // 确认 executionDelivery 模式不走创意路径
        let brief = AgentTeamMissionBrief(
            objective: "修复 bug",
            constraints: [],
            acceptanceCriteria: ["Tests pass"],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
            initialContextSummary: ""
        )

        let board = AgentTeamTaskBoardCoordinator().bootstrapBoard(
            from: brief, preferredProvider: .builtIn
        )

        let creativeDrafts = board.cards.filter { $0.kind == .creativeDraft }
        let synthesis = board.cards.filter { $0.kind == .synthesis }

        #expect(creativeDrafts.isEmpty)
        #expect(synthesis.isEmpty)
    }
}

// MARK: - Task 3: Creative Prompt Builders

struct AgentTeamCreativePromptBuilderTests {

    private let brief = AgentTeamMissionBrief(
        objective: "为「极简记账」设计 App Icon",
        constraints: ["避免使用金融图标俗套"],
        acceptanceCriteria: ["独特、易识别"],
        mode: .creativeExploration,
        dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
        initialContextSummary: "App 定位：极简主义, 用色纯白"
    )

    private var draftCard: AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            title: "App Icon 草案 1",
            goal: "为「极简记账」设计 App Icon",
            status: .briefed,
            kind: .creativeDraft,
            creativeGroupID: UUID(uuidString: "60606060-6060-6060-6060-606060606060")!,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var synthesisCard: AgentTeamTaskCard {
        AgentTeamTaskCard(
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            title: "App Icon 综合",
            goal: "综合并收敛各草案",
            status: .briefed,
            kind: .synthesis,
            creativeGroupID: UUID(uuidString: "60606060-6060-6060-6060-606060606060")!,
            lastUpdatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test
    func creativeDraftPromptIncludesDraftIndexLabel() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        #expect(prompt.contains("草案 1 / 2"))
    }

    @Test
    func creativeDraftPromptIncludesIsolationInstruction() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        // 确保有明确的草案隔离指令
        #expect(prompt.contains("不要参考") || prompt.contains("do not read") || prompt.contains("独立"))
    }

    @Test
    func creativeDraftPromptIncludesBriefObjective() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 1, totalDrafts: 3)

        #expect(prompt.contains("极简记账"))
    }

    @Test
    func creativeDraftPromptDoesNotLeakOtherDraftContent() {
        // draft prompt 不包含任何来自 artifact 的内容（只有 brief）
        let prompt = AgentTeamMissionPromptBuilder()
            .buildCreativeDraftPrompt(brief: brief, card: draftCard, draftIndex: 0, totalDrafts: 2)

        #expect(!prompt.contains("Existing Artifacts"))
    }

    @Test
    func synthesisPromptIncludesDraftArtifactContent() {
        let draftArtifacts = [
            AgentTeamArtifact(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                kind: .ideaDraft,
                title: "方案 A：几何图形",
                producer: .builtIn,
                taskCardID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                version: 1,
                summary: "使用简洁几何线条",
                payload: .text("使用细线正方形，白底，淡金色边框"),
                status: .submitted
            ),
            AgentTeamArtifact(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                kind: .ideaDraft,
                title: "方案 B：字母标志",
                producer: .externalACP(profileID: AgentTeamBootstrapCreativeBoardTests.copilotProfileID),
                taskCardID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                version: 1,
                summary: "以「记」字变形为核心",
                payload: .text("将「记」字解构为现代字体"),
                status: .submitted
            )
        ]

        let prompt = AgentTeamMissionPromptBuilder()
            .buildSynthesisPrompt(brief: brief, synthesisCard: synthesisCard, draftArtifacts: draftArtifacts)

        #expect(prompt.contains("方案 A：几何图形"))
        #expect(prompt.contains("方案 B：字母标志"))
    }

    @Test
    func synthesisPromptIncludesObjectiveAndSynthesisInstruction() {
        let prompt = AgentTeamMissionPromptBuilder()
            .buildSynthesisPrompt(brief: brief, synthesisCard: synthesisCard, draftArtifacts: [])

        #expect(prompt.contains("极简记账"))
        // 有收敛指令
        #expect(prompt.contains("综合") || prompt.contains("synthesis") || prompt.contains("收敛"))
    }
}

// MARK: - Task 4: claimBatch prompt routing

@MainActor
struct AgentTeamClaimBatchCreativeRoutingTests {

    private let copilotProfileID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    private func makeCreativeState(
        providers: [ExecutionProviderReference] = [
            .builtIn,
            .externalACP(profileID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!)
        ]
    ) -> AgentTeamSessionState {
        let session = Session.fixture(title: "Creative Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session, mode: .creativeExploration, status: .created)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "设计 App Icon",
            constraints: [],
            acceptanceCriteria: [],
            mode: .creativeExploration,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 3),
            initialContextSummary: "",
            providerPlan: .init(
                eligibleProviders: providers,
                preferredConductor: .builtIn,
                preferredReviewer: nil,
                dispatchPolicy: .autoClaim
            )
        )
        // state.taskBoardState = nil → claimBatch 将 bootstrapBoard → creativeExploration 路径
        return state
    }

    @Test
    func claimBatchProducesDraftPromptForCreativeDraftCard() throws {
        let state = makeCreativeState()
        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        let draftResults = results.filter { result in
            state.taskBoardState?.card(id: result.primaryCardID)?.kind == .creativeDraft
        }
        #expect(draftResults.count == 2)
        // draft prompt 包含隔离提示，不包含 "Existing Artifacts"
        for r in draftResults {
            #expect(r.missionPrompt.contains("草案"))
            #expect(!r.missionPrompt.contains("Existing Artifacts"))
        }
    }

    @Test
    func claimBatchDoesNotDispatchSynthesisInFirstWave() throws {
        let state = makeCreativeState()
        let results = try AgentTeamLaunchCoordinator().claimBatch(state: state)

        let synthesisResults = results.filter { result in
            state.taskBoardState?.card(id: result.primaryCardID)?.kind == .synthesis
        }
        // synthesis 依赖 draft，wave 1 不应出现 synthesis
        #expect(synthesisResults.isEmpty)
    }

    @Test
    func claimBatchAssignsConductorToSynthesisCard() throws {
        let state = makeCreativeState()
        let coordinator = AgentTeamLaunchCoordinator()

        // Wave 1: draft cards
        let wave1 = try coordinator.claimBatch(state: state)
        #expect(wave1.count == 2)

        // Manually mark all draft cards as done
        if var taskBoard = state.taskBoardState {
            for i in 0..<taskBoard.cards.count where taskBoard.cards[i].kind == .creativeDraft {
                taskBoard.cards[i] = AgentTeamTaskCard(
                    id: taskBoard.cards[i].id,
                    title: taskBoard.cards[i].title,
                    goal: taskBoard.cards[i].goal,
                    status: .done,
                    kind: .creativeDraft,
                    creativeGroupID: taskBoard.cards[i].creativeGroupID,
                    owner: taskBoard.cards[i].owner,
                    acceptedClaimID: taskBoard.cards[i].acceptedClaimID,
                    lastUpdatedAt: Date()
                )
            }
            state.taskBoardState = taskBoard
        }

        // Wave 2: synthesis card should now appear
        let wave2 = try coordinator.claimBatch(state: state)
        #expect(wave2.count == 1)

        let synthesisResult = wave2[0]
        let synthesisCardOwner = state.taskBoardState?.card(id: synthesisResult.primaryCardID)?.owner
        #expect(synthesisCardOwner == .builtIn) // preferredConductor
    }

    @Test
    func synthesisMissionPromptIncludesDraftArtifactsWhenPresent() throws {
        let state = makeCreativeState()
        let coordinator = AgentTeamLaunchCoordinator()

        // Wave 1
        let wave1 = try coordinator.claimBatch(state: state)
        #expect(!wave1.isEmpty)

        // Add ideaDraft artifacts for each draft card
        var artifactBoard = state.artifactBoardState ?? AgentTeamArtifactBoardState()
        var taskBoard = state.taskBoardState!

        for (i, result) in wave1.enumerated() {
            let artifact = AgentTeamArtifact(
                id: UUID(),
                kind: .ideaDraft,
                title: "草案方案 \(i + 1)",
                producer: result.executionTarget.providerReference,
                taskCardID: result.primaryCardID,
                version: 1,
                summary: "独特的创意方向 \(i + 1)",
                payload: .text("方案内容 \(i + 1): 具体描述"),
                status: .submitted
            )
            artifactBoard.artifacts.append(artifact)
            if let idx = taskBoard.cards.firstIndex(where: { $0.id == result.primaryCardID }) {
                taskBoard.cards[idx].artifactIDs.append(artifact.id)
            }
            // Mark done
            if let idx = taskBoard.cards.firstIndex(where: { $0.id == result.primaryCardID }) {
                taskBoard.cards[idx] = AgentTeamTaskCard(
                    id: taskBoard.cards[idx].id,
                    title: taskBoard.cards[idx].title,
                    goal: taskBoard.cards[idx].goal,
                    status: .done,
                    kind: .creativeDraft,
                    creativeGroupID: taskBoard.cards[idx].creativeGroupID,
                    owner: taskBoard.cards[idx].owner,
                    acceptedClaimID: taskBoard.cards[idx].acceptedClaimID,
                    lastUpdatedAt: Date()
                )
            }
        }
        state.taskBoardState = taskBoard
        state.artifactBoardState = artifactBoard

        // Wave 2: synthesis
        let wave2 = try coordinator.claimBatch(state: state)
        #expect(wave2.count == 1)

        let synthesisPrompt = wave2[0].missionPrompt
        #expect(synthesisPrompt.contains("草案方案 1"))
        #expect(synthesisPrompt.contains("草案方案 2"))
    }
}
