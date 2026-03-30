import Testing
@testable import agentGui

@MainActor
struct AgentTeamWorkbenchPresentationTests {
    @Test
    func presentationBuildsMissionHeaderFromState() {
        let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
        let state = AgentTeamSessionState(
            session: session,
            sourceSessionID: "chat-1",
            sourceSessionTitle: "修复 ACP",
            mode: .executionDelivery,
            status: .active
        )

        let presentation = AgentTeamWorkbenchPresentation.make(session: session, state: state)

        #expect(presentation.header.title == "修复 ACP")
        #expect(presentation.header.statusText == "进行中")
        #expect(presentation.header.objectiveSummary.contains("修复 ACP"))
        #expect(presentation.header.sourceSummary.contains("修复 ACP"))
        #expect(presentation.header.modeText == "执行交付")
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
        #expect(presentation.inspector.title.contains("待选中"))
    }
}