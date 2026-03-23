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

    @Test func builtInApprovalModeFallsBackToGlobalSettingWhenSessionOverrideMissing() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture(selectedModel: "claude-sonnet-4-6")
        settings.builtInDefaultApprovalMode = "default"

        #expect(SessionExecutionPreferencesResolver.builtInApprovalMode(for: session, settings: settings) == .defaultApprovals)
    }

    @Test func builtInApprovalModeUsesSessionOverrideWhenPresent() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture(selectedModel: "claude-sonnet-4-6")
        settings.builtInDefaultApprovalMode = "default"
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            builtInApprovalMode: "never",
            gitHubCopilotCLI: .init()
        )

        #expect(SessionExecutionPreferencesResolver.builtInApprovalMode(for: session, settings: settings) == .bypassApprovals)
    }

    @Test func copilotConfigurationMergesSessionOverridesOverGlobalDefaults() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture()
        settings.githubCopilotCLIConfiguration = ACPCLIConfiguration(
            executablePath: "copilot",
            defaultModel: "gpt-5",
            defaultApprovalMode: "default"
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

    @Test func openCodeConfigurationMergesSessionOverridesOverGlobalDefaults() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture()
        settings.openCodeCLIConfiguration = ACPCLIConfiguration(
            executablePath: "opencode",
            defaultModel: "openai/gpt-5",
            defaultApprovalMode: "default"
        )
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            gitHubCopilotCLI: .init(),
            openCodeCLI: OpenCodeCLISessionPreferences(
                modelID: "anthropic/claude-sonnet-4-5",
                approvalMode: "never"
            )
        )

        let resolved = SessionExecutionPreferencesResolver.openCodeCLIConfiguration(for: session, settings: settings)

        #expect(resolved.defaultModel == "anthropic/claude-sonnet-4-5")
        #expect(resolved.defaultApprovalMode == "never")
        #expect(resolved.executablePath == "opencode")
    }

    @Test func claudeAdapterConfigurationMergesSessionOverridesOverGlobalDefaults() {
        let session = Session.fixture()
        let settings = AppSettings.testFixture()
        settings.claudeAdapterCLIConfiguration = ACPCLIConfiguration(
            executablePath: "claude-agent-acp",
            defaultModel: "claude-sonnet-4-6",
            defaultApprovalMode: "default"
        )
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            gitHubCopilotCLI: .init(),
            openCodeCLI: .init(),
            claudeAdapterCLI: ClaudeAdapterCLISessionPreferences(
                modelID: "claude-opus-4-6",
                approvalMode: "never"
            )
        )

        let resolved = SessionExecutionPreferencesResolver.claudeAdapterCLIConfiguration(for: session, settings: settings)

        #expect(resolved.defaultModel == "claude-opus-4-6")
        #expect(resolved.defaultApprovalMode == "never")
        #expect(resolved.executablePath == "claude-agent-acp")
    }
}