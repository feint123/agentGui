import Testing
@testable import agentGui

@MainActor
struct AgentTeamMissionBriefResolverTests {
    @Test
    func sameSessionProducesSingleCanonicalBriefForAllRoles() {
        let session = Session.fixture(title: "ACP Agent Team", kind: .agentTeam)
        let state = AgentTeamSessionState(session: session)
        state.missionBrief = AgentTeamMissionBrief(
            objective: "统一修复 ACP team",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        let resolver = AgentTeamMissionBriefResolver()

        let conductor = resolver.resolve(session: session, state: state, role: "conductor")
        let worker = resolver.resolve(session: session, state: state, role: "worker")
        let reviewer = resolver.resolve(session: session, state: state, role: "reviewer")

        #expect(conductor.brief == worker.brief)
        #expect(worker.brief == reviewer.brief)
        #expect(conductor.isFallback == false)
    }

    @Test
    func resolverBuildsLegacyFallbackWhenPersistedBriefIsMissing() {
        let session = Session.fixture(title: "ACP Agent Team", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP",
            mode: .executionDelivery,
            status: .active
        )

        let resolution = AgentTeamMissionBriefResolver().resolve(session: session, state: state)

        #expect(resolution.isFallback == true)
        #expect(resolution.brief.objective.isEmpty == false)
        #expect(resolution.brief.initialContextSummary.contains("修复 ACP"))
        #expect(resolution.brief.mode == .executionDelivery)
    }
}