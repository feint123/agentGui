import Testing
@testable import agentGui

struct AgentStudioWindowSceneTests {
    @Test func sceneIdentifierIsStable() {
        #expect(AgentStudioWindowScene.id == "agent-studio-window")
    }
}