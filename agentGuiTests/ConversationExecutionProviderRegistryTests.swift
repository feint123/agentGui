import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionProviderRegistryTests {
    @Test func registryResolvesSessionOverrideBeforeGlobalDefault() throws {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI)
        )
        let session = Session.fixture()
        let settings = AppSettings.testFixture(apiKey: "test")
        settings.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue

        #expect(registry.provider(for: session, settings: settings).id == .githubCopilotCLI)
    }

    @Test func registryFallsBackToGlobalDefaultWhenSessionProviderMissing() throws {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI)
        )
        let session = Session.fixture()
        let settings = AppSettings.testFixture(apiKey: "test")
        settings.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        session.defaultExecutionProviderID = ""

        #expect(registry.provider(for: session, settings: settings).id == .githubCopilotCLI)
    }

    @Test func claudeServiceRoutesSendThroughResolvedProvider() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue
        let session = Session.fixture(title: "Routing")
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let builtIn = ProviderSpy(id: .builtInAgent)
        let copilot = ProviderSpy(id: .githubCopilotCLI)
        let claudeService = ClaudeService()
        claudeService.executionProviderRegistry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot
        )

        try await claudeService.sendMessage(
            text: "hello",
            session: session,
            modelId: "claude-test",
            modelContext: modelContext
        )

        #expect(copilot.sentTexts == ["hello"])
        #expect(builtIn.sentTexts.isEmpty)
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }
}

@MainActor
private final class ProviderSpy: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID
    private(set) var sentTexts: [String] = []

    init(id: ConversationExecutionProviderID) {
        self.id = id
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        sentTexts.append(request.text)
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        _ = request
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        _ = request
    }

    func cancel(session: Session, modelContext: ModelContext) async {
        _ = session
        _ = modelContext
    }
}