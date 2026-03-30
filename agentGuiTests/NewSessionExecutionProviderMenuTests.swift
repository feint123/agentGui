import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct NewSessionExecutionProviderMenuTests {
    @Test
    func buildActionsPrependsAgentTeamAction() {
        let source = Session.fixture(sessionId: "chat-1", title: "当前聊天", kind: .local)
        let actions = NewSessionExecutionProviderMenu<EmptyView>.buildActions(
            providerOptions: [
                ExecutionOptionItem(
                    id: ExecutionProviderReference.builtIn.persistedValue,
                    title: "内置 Agent"
                )
            ],
            sourceSession: source
        )

        #expect(actions.first == .agentTeam(source: .init(session: source)))
        #expect(actions.dropFirst().count == 1)
    }

    @Test
    func buildActionsSupportsStandaloneTeamCreation() {
        let actions = NewSessionExecutionProviderMenu<EmptyView>.buildActions(
            providerOptions: [],
            sourceSession: nil
        )

        #expect(actions == [.agentTeam(source: nil)])
        #expect(actions.first?.title == "Team Mode")
    }
}