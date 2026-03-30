import Testing
@testable import agentGui

@MainActor
struct WorkbenchConversationPaneTests {
    @Test
    func agentTeamSessionUsesDedicatedSurface() {
        let session = Session.fixture(title: "团队壳层", kind: .agentTeam)

        #expect(WorkbenchConversationPane.surface(for: session) == .agentTeam)
    }

    @Test
    func localSessionContinuesToUseChatSurface() {
        let session = Session.fixture(title: "普通对话", kind: .local)

        #expect(WorkbenchConversationPane.surface(for: session) == .chat)
    }

    @Test
    func agentTeamSurfacePublishesStableAccessibilityIdentifiers() {
        #expect(AgentTeamSessionView.panelAccessibilityIdentifier == "panel.agentTeam")
        #expect(AgentTeamSessionView.missionHeaderAccessibilityIdentifier == "agentTeam.missionHeader")
        #expect(AgentTeamSessionView.rosterAccessibilityIdentifier == "agentTeam.roster")
        #expect(AgentTeamSessionView.boardAccessibilityIdentifier == "agentTeam.board")
        #expect(AgentTeamSessionView.inspectorAccessibilityIdentifier == "agentTeam.inspector")
    }
}