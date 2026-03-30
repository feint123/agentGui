import Testing
@testable import agentGui

struct SessionKindTests {
    @Test
    func agentTeamKindHasStablePresentation() {
        #expect(SessionKind.allCases.contains(.agentTeam))
        #expect(SessionKind.agentTeam.displayName == "Agent Team")
        #expect(SessionKind.agentTeam.defaultSourceTitle == "Agent Team")
    }
}