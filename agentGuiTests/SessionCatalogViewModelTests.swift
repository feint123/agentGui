import Testing
@testable import agentGui

@MainActor
struct SessionCatalogViewModelTests {
    @Test
    func agentTeamSessionsAppearInCatalogSections() {
        let chat = Session.fixture(title: "普通对话", kind: .local)
        let team = Session.fixture(title: "团队壳层", kind: .agentTeam)
        let viewModel = SessionCatalogViewModel()

        viewModel.setSessions([chat, team])

        let teamSection = viewModel.visibleSections.first(where: { $0.kind == .agentTeam })
        #expect(teamSection?.title == "Agent Team")
        #expect(teamSection?.items.map(\ .session.sessionId) == [team.sessionId])
    }

    @Test
    func agentTeamCatalogItemsUseExplicitPolicy() throws {
        let team = Session.fixture(title: "团队壳层", kind: .agentTeam)
        let viewModel = SessionCatalogViewModel()

        viewModel.setSessions([team])

        let item = try #require(viewModel.visibleSections.first?.items.first)
        #expect(item.canRename)
        #expect(item.canDelete)
    }
}