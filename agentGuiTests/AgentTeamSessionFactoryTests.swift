import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentTeamSessionFactoryTests {
    @Test
    func createFromChatPersistsMissionBriefIntoState() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let source = Session(title: "当前聊天", kind: .local)
        context.insert(source)

        var draft = AgentTeamMissionBriefDraft.prefilled(from: source)
        draft.objective = "为 ACP team 生成修复计划"
        draft.constraintsText = "仅修改 Swift 文件\n保持 focused tests"
        draft.acceptanceCriteriaText = "Mission Header 回显 brief\nteam session 持久化 brief"
        draft.maxActiveProviders = 2
        draft.tokenBudgetText = "20k"
        draft.costBudgetText = "medium"
        draft.initialContextSummary = "来源聊天包含失败测试与日志。"

        let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)

        #expect(result.session.kind == SessionKind.agentTeam)
        #expect(result.session.title == "当前聊天 · Team")
        #expect(result.state.session === result.session)
        #expect(result.state.sourceSessionID == source.sessionId)
        #expect(result.state.sourceSessionTitle == source.title)
        #expect(result.state.mode == .executionDelivery)
        #expect(result.state.missionBrief?.objective == "为 ACP team 生成修复计划")
        #expect(result.state.missionBrief?.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
    }

    @Test
    func createWithoutSourceBuildsStandaloneAgentTeamSessionWithFallbackBrief() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let result = try AgentTeamSessionFactory().create(from: nil, modelContext: context)

        #expect(result.session.kind == SessionKind.agentTeam)
        #expect(result.state.sourceSessionID.isEmpty)
        #expect(result.state.sourceSessionTitle.isEmpty)
        #expect(result.state.missionBrief != nil)
        #expect(result.state.missionBrief?.objective.isEmpty == false)
    }

    @Test
    func createFromChatBootstrapsClaimBoardFromCanonicalBrief() throws {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let source = Session(title: "当前聊天", kind: .local)
        source.defaultExecutionProviderReference = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        context.insert(source)

        var draft = AgentTeamMissionBriefDraft.prefilled(from: source)
        draft.objective = "为 ACP team 生成修复计划"
        draft.constraintsText = "仅修改 Swift 文件\n保持 focused tests"
        draft.acceptanceCriteriaText = "Mission Header 回显 brief\nteam session 持久化 brief"
        draft.maxActiveProviders = 2
        draft.tokenBudgetText = "20k"
        draft.costBudgetText = "medium"
        draft.initialContextSummary = "来源聊天包含失败测试与日志。"

        let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)
        let board = try #require(result.state.claimBoardState)
        let card = try #require(board.cards.first)

        #expect(result.session.defaultExecutionProviderReference == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference)
        #expect(card.title.isEmpty == false)
        #expect(card.goal.contains("为 ACP team 生成修复计划"))
        #expect(card.owner == nil)
        #expect(board.claims.isEmpty)
    }
}