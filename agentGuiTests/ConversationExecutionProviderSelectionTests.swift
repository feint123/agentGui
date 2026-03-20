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

    @Test func providerOptionsDisableCopilotWhenUnavailable() {
        let options = ConversationExecutionProviderID.optionItems(
            copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus(kind: .notInstalled, version: nil)
        )

        #expect(options.map(\.id) == [
            ConversationExecutionProviderID.builtInAgent.rawValue,
            ConversationExecutionProviderID.githubCopilotCLI.rawValue
        ])
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.builtInAgent.rawValue })?.isEnabled == true)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.githubCopilotCLI.rawValue })?.isEnabled == false)
    }
}