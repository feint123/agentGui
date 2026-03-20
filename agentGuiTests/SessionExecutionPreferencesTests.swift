import Testing
@testable import agentGui

@MainActor
struct SessionExecutionPreferencesTests {
    @Test func builtInModelFallsBackToGlobalSettingWhenSessionOverrideMissing() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture(selectedModel: "claude-sonnet-4-6")

        #expect(SessionExecutionPreferencesResolver.builtInModelID(for: session, settings: settings) == "claude-sonnet-4-6")
    }

    @Test func builtInModelUsesSessionOverrideWhenPresent() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture(selectedModel: "claude-sonnet-4-6")
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: "claude-opus-4-6",
            gitHubCopilotCLI: .init()
        )

        #expect(SessionExecutionPreferencesResolver.builtInModelID(for: session, settings: settings) == "claude-opus-4-6")
    }

    @Test func copilotConfigurationMergesSessionOverridesOverGlobalDefaults() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture()
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "copilot",
            defaultModel: "gpt-5",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            gitHubCopilotCLI: GitHubCopilotCLISessionPreferences(
                modelID: "gpt-5-mini",
                approvalMode: "never"
            )
        )

        let resolved = SessionExecutionPreferencesResolver.gitHubCopilotCLIConfiguration(for: session, settings: settings)

        #expect(resolved.defaultModel == "gpt-5-mini")
        #expect(resolved.defaultApprovalMode == "never")
        #expect(resolved.executablePath == "copilot")
    }
}