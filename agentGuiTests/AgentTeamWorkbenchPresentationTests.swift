import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationPrefersPersistedMissionBrief() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP",
            mode: .executionDelivery,
            status: .active
        )
        state.missionBrief = AgentTeamMissionBrief(
            objective: "为 ACP team 汇总修复方案",
            constraints: ["不改 public API"],
            acceptanceCriteria: ["Focused tests 通过"],
            mode: .executionDelivery,
            budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium"),
            initialContextSummary: "当前聊天包含失败测试与日志。"
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.header.title == "修复 ACP")
        #expect(presentation.header.statusText == "进行中")
        #expect(presentation.header.objectiveSummary == "为 ACP team 汇总修复方案")
        #expect(presentation.header.sourceSummary.contains("修复 ACP"))
        #expect(presentation.header.modeText == "执行交付")
        #expect(presentation.header.constraints == ["不改 public API"])
        #expect(presentation.header.acceptanceCriteria == ["Focused tests 通过"])
        #expect(presentation.header.contextSummary.contains("失败测试"))
        #expect(presentation.header.budgetSummary == "预算：并发 2 · Token 20k · 成本 medium")
        #expect(presentation.header.isFallbackBrief == false)
        #expect(presentation.roster.count == 3)
        #expect(presentation.roster.map(\ .role) == ["conductor", "worker", "reviewer"])
        #expect(presentation.boardColumns.count >= 3)
        #expect(presentation.boardColumns.map(\ .title) == ["Briefing", "Working", "Reviewing"])
    }

    @Test
    func presentationFallsBackWhenStateIsMissing() {
        let session = Session.fixture(title: "Agent Team", kind: .agentTeam)

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: nil)

        #expect(presentation.header.title == "Agent Team")
        #expect(presentation.header.statusText == "待开始")
        #expect(presentation.header.sourceSummary.contains("无来源聊天"))
        #expect(presentation.header.isFallbackBrief == true)
        #expect(presentation.header.constraints.isEmpty == false)
        #expect(presentation.header.acceptanceCriteria.isEmpty == false)
        #expect(presentation.inspector.title.contains("待选中"))
    }
}