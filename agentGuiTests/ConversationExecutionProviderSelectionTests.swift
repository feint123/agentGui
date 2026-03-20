import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionProviderSelectionTests {
    @Test func appSettingsDefaultsToBuiltInAgent() {
        let settings = AppSettings()

        #expect(settings.defaultExecutionProviderID == ConversationExecutionProviderID.builtInAgent.rawValue)
        #expect(settings.githubCopilotCLIConfiguration.useACPStdIO == true)
    }

    @Test func sessionCanOverrideGlobalExecutionProvider() {
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue

        #expect(session.executionProviderID == .githubCopilotCLI)
    }
}