import Testing
@testable import agentGui

@MainActor
struct SessionInteractionPolicyTests {
    @Test
    func agentTeamPolicyDisablesChatComposerActions() {
        let team = Session.fixture(title: "团队壳层", kind: .agentTeam)
        let policy = SessionInteractionPolicy(session: team)

        #expect(policy.canSend == false)
        #expect(policy.canClearMessages == false)
        #expect(policy.canRename)
        #expect(policy.canDelete)
    }
}