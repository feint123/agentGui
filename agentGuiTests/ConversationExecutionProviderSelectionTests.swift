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
    }

    @Test func sessionCanOverrideGlobalExecutionProvider() {
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue

        #expect(session.executionProviderID == .githubCopilotCLI)
    }

    @Test func providerOptionsDisableCopilotWhenUnavailable() {
        let options = ConversationExecutionProviderID.optionItems(
            copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus(kind: .notInstalled, version: nil),
            openCodeAvailabilityStatus: ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: "OpenCode")
        )

        #expect(options.map(\.id) == [
            ConversationExecutionProviderID.builtInAgent.rawValue,
            ConversationExecutionProviderID.githubCopilotCLI.rawValue,
            ConversationExecutionProviderID.openCodeCLI.rawValue
        ])
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.builtInAgent.rawValue })?.isEnabled == true)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.githubCopilotCLI.rawValue })?.isEnabled == false)
        #expect(options.first(where: { $0.id == ConversationExecutionProviderID.openCodeCLI.rawValue })?.isEnabled == false)
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

    @Test func registryRoutesOpenCodeSessionsToOpenCodeProvider() {
        let builtInProvider = SelectionProviderStub(id: .builtInAgent)
        let copilotProvider = SelectionProviderStub(id: .githubCopilotCLI)
        let openCodeProvider = SelectionProviderStub(id: .openCodeCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtInProvider,
            copilot: copilotProvider,
            openCode: openCodeProvider
        )
        let settings = AppSettings()
        let session = Session.fixture()
        session.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue

        let resolved = registry.provider(for: session, settings: settings)

        #expect(resolved.id == .openCodeCLI)
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