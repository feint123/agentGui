import Testing
import SwiftData
@testable import agentGui

@MainActor
struct ConversationExecutionProviderSelectionTests {
    @Test func appSettingsDefaultsToBuiltInAgent() {
        let settings = AppSettings()

        #expect(settings.defaultExecutionProviderID == ConversationExecutionProviderID.builtInAgent.rawValue)
        #expect(settings.githubCopilotCLIConfiguration == ACPCLIConfiguration(
            executablePath: "copilot",
            defaultModel: "",
            defaultApprovalMode: "default"
        ))
        #expect(settings.claudeAdapterCLIConfiguration == ACPCLIConfiguration(
            executablePath: "claude-agent-acp",
            defaultModel: "",
            defaultApprovalMode: "default"
        ))
    }

    @Test func sessionCanOverrideGlobalExecutionProvider() {
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue

        #expect(session.executionProviderID == .githubCopilotCLI)
    }

    @Test func providerOptionsDisableCopilotWhenUnavailable() {
        let options = ConversationExecutionProviderID.optionItems(
            copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus(kind: .notInstalled, version: nil),
            openCodeAvailabilityStatus: ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: "OpenCode"),
            claudeAdapterAvailabilityStatus: ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: "Claude Adapter")
        )

        #expect(options.map(\.id) == [
            ConversationExecutionProviderID.builtInAgent.rawValue,
            ConversationExecutionProviderID.githubCopilotCLI.rawValue,
            ConversationExecutionProviderID.openCodeCLI.rawValue,
            ConversationExecutionProviderID.claudeAdapterCLI.rawValue
        ])
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.builtInAgent.rawValue })?.isEnabled == true)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.githubCopilotCLI.rawValue })?.isEnabled == false)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.openCodeCLI.rawValue })?.isEnabled == false)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.claudeAdapterCLI.rawValue })?.isEnabled == false)
    }

    @Test func providerOptionsKeepAuthenticatedRemediationPathsSelectable() {
        let options = ConversationExecutionProviderID.optionItems(
            copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus(kind: .notAuthenticated, version: nil),
            openCodeAvailabilityStatus: ACPCLIAvailabilityStatus(kind: .notAuthenticated, version: nil, displayName: "OpenCode"),
            claudeAdapterAvailabilityStatus: ACPCLIAvailabilityStatus(kind: .notAuthenticated, version: nil, displayName: "Claude Code")
        )

        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.githubCopilotCLI.rawValue })?.isEnabled == true)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.openCodeCLI.rawValue })?.isEnabled == true)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.claudeAdapterCLI.rawValue })?.isEnabled == true)
    }

    @Test func appSettingsPersistsOpenCodeDefaults() {
        let settings = AppSettings()

        #expect(ConversationExecutionProviderID(rawValue: "opencode_cli") == .openCodeCLI)
        #expect(settings.openCodeCLIConfiguration == ACPCLIConfiguration(
            executablePath: "opencode",
            defaultModel: "",
            defaultApprovalMode: "default"
        ))
        #expect(ACPExternalAgentDescriptor.openCode.defaultArguments == ["acp"])
    }

    @Test func appSettingsPersistsClaudeAdapterDefaults() {
        let settings = AppSettings()

        #expect(ConversationExecutionProviderID(rawValue: "claude_adapter_cli") == .claudeAdapterCLI)
        #expect(settings.claudeAdapterCLIConfiguration == ACPCLIConfiguration(
            executablePath: "claude-agent-acp",
            defaultModel: "",
            defaultApprovalMode: "default"
        ))
        #expect(ACPExternalAgentDescriptor.claudeAdapter.defaultArguments.isEmpty)
    }

    @Test func registryRoutesOpenCodeSessionsToOpenCodeProvider() {
        let builtInProvider = SelectionProviderStub(id: .builtInAgent)
        let copilotProvider = SelectionProviderStub(id: .githubCopilotCLI)
        let openCodeProvider = SelectionProviderStub(id: .openCodeCLI)
        let claudeAdapterProvider = SelectionProviderStub(id: .claudeAdapterCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtInProvider,
            copilot: copilotProvider,
            openCode: openCodeProvider,
            claudeAdapter: claudeAdapterProvider
        )
        let settings = AppSettings()
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue

        let resolved = registry.provider(for: session, settings: settings)

        #expect(resolved.id == .openCodeCLI)
    }

    @Test func registryRoutesClaudeAdapterSessionsToClaudeAdapterProvider() {
        let builtInProvider = SelectionProviderStub(id: .builtInAgent)
        let copilotProvider = SelectionProviderStub(id: .githubCopilotCLI)
        let openCodeProvider = SelectionProviderStub(id: .openCodeCLI)
        let claudeAdapterProvider = SelectionProviderStub(id: .claudeAdapterCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtInProvider,
            copilot: copilotProvider,
            openCode: openCodeProvider,
            claudeAdapter: claudeAdapterProvider
        )
        let settings = AppSettings()
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.claudeAdapterCLI.rawValue

        let resolved = registry.provider(for: session, settings: settings)

        #expect(resolved.id == .claudeAdapterCLI)
    }
}

@MainActor
private final class SelectionProviderStub: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID

    init(id: ConversationExecutionProviderID) {
        self.id = id
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        _ = request
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        _ = request
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        _ = request
    }

    func cancel(session: Session, modelContext: SwiftData.ModelContext) async {
        _ = session
        _ = modelContext
    }
}