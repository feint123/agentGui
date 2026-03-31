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
        draft.initialContextSummary = "来源聊天包含失败测试与日志。"
        draft.eligibleProviderIDs = [
            ExecutionProviderReference.builtIn.persistedValue,
            LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference.persistedValue
        ]
        draft.preferredConductorID = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference.persistedValue

        let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)

        #expect(result.session.kind == SessionKind.agentTeam)
        #expect(result.session.title == "当前聊天 · Team")
        #expect(result.state.session === result.session)
        #expect(result.state.sourceSessionID == source.sessionId)
        #expect(result.state.sourceSessionTitle == source.title)
        #expect(result.state.mode == .executionDelivery)
        #expect(result.state.missionBrief?.objective == "为 ACP team 生成修复计划")
        #expect(result.state.missionBrief?.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
        #expect(result.state.missionBrief?.providerPlan.preferredConductor == LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference)
        #expect(result.session.defaultExecutionProviderReference == LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference)
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
    func createFromChatBootstrapsTaskBoardFromCanonicalBrief() throws {
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
        draft.initialContextSummary = "来源聊天包含失败测试与日志。"

        let result = try AgentTeamSessionFactory().create(from: source, draft: draft, modelContext: context)
        let board = try #require(result.state.taskBoardState)
        let card = try #require(board.cards.first)
        let legacyBoard = try #require(result.state.claimBoardState)

        #expect(result.session.defaultExecutionProviderReference == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference)
        #expect(board.cards.count == 3)
        #expect(card.title == "为 ACP team 生成修复计划")
        #expect(card.goal.contains("为 ACP team 生成修复计划"))
        #expect(card.status == .briefed)
        #expect(card.owner == nil)
        #expect(card.dependencyIDs.isEmpty)
        #expect(board.cards.dropFirst().allSatisfy { $0.dependencyIDs == [card.id] })
        #expect(board.claims.isEmpty)
        #expect(legacyBoard.cards.count == board.cards.count)
    }
}