import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationExecutionProviderRegistryTests {
    @Test func registryResolvesSessionOverrideBeforeGlobalDefault() throws {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
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
            copilot: ProviderSpy(id: .githubCopilotCLI),
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let session = Session.fixture()
        let settings = AppSettings.testFixture(apiKey: "test")
        settings.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        session.defaultExecutionProviderID = ""

        #expect(registry.provider(for: session, settings: settings).id == .githubCopilotCLI)
    }

    @Test func registryBuildsCompatibilityDriverForResolvedProvider() throws {
        let registry = ConversationExecutionProviderRegistry(
            builtIn: ProviderSpy(id: .builtInAgent),
            copilot: ProviderSpy(id: .githubCopilotCLI, runtimeScope: .externalACP),
            openCode: ProviderSpy(id: .openCodeCLI, runtimeScope: .externalACP)
        )

        let driver = registry.compatibilityDriver(for: .githubCopilotCLI)

        #expect(driver.providerID == .githubCopilotCLI)
        #expect(driver.runtimeScope == .externalACP)
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
            copilot: copilot,
            openCode: ProviderSpy(id: .openCodeCLI)
        )

        try await claudeService.sendMessage(
            text: "hello",
            session: session,
            modelId: "claude-test",
            modelContext: modelContext
        )

        await waitUntil { copilot.sentTexts == ["hello"] }

        #expect(copilot.sentTexts == ["hello"])
        #expect(builtIn.sentTexts.isEmpty)
    }

    @Test func claudeServicePersistsExecutionJobWhenOrchestratorIsAvailable() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        let session = Session.fixture(title: "Queue Path")
        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let projectionStore = ExecutionProjectionStore()
        let persistenceCoordinator = PersistenceCoordinator(saveOperation: { try $0.save() })
        let builtIn = ProviderSpy(id: .builtInAgent)
        let copilot = ProviderSpy(id: .githubCopilotCLI)
        let registry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot,
            openCode: ProviderSpy(id: .openCodeCLI)
        )
        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: modelContext,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: modelContext,
                persistenceCoordinator: persistenceCoordinator
            ),
            projectionStore: projectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 1),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: registry,
            runtimeCoordinator: ConversationExecutionRuntimeCoordinator()
        )

        let claudeService = ClaudeService()
        claudeService.executionProviderRegistry = registry
        claudeService.executionOrchestrator = orchestrator

        try await claudeService.sendMessage(
            text: "hello",
            session: session,
            modelId: "claude-test",
            modelContext: modelContext
        )

        await waitUntil { copilot.sentTexts == ["hello"] }

        #expect(copilot.sentTexts == ["hello"])
        #expect(try modelContext.fetch(FetchDescriptor<ExecutionJob>()).count == 1)
        #expect(session.messages.contains { $0.direction == .agent })
    }

    @Test func claudeServicePreparesExternalACPScopeBeforeSwitchingProvidersInSameSession() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        let session = Session.fixture(title: "Routing")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let harness = ExternalACPConflictHarness()
        let builtIn = ProviderSpy(id: .builtInAgent)
        let copilot = ProviderSpy(id: .githubCopilotCLI, runtimeScope: .externalACP, conflictHarness: harness)
        let openCode = ProviderSpy(id: .openCodeCLI, runtimeScope: .externalACP, conflictHarness: harness)
        let claudeService = ClaudeService()
        claudeService.executionProviderRegistry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot,
            openCode: openCode
        )

        session.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        try await claudeService.sendMessage(
            text: "copilot first",
            session: session,
            modelId: "claude-test",
            modelContext: modelContext
        )

        session.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue
        try await claudeService.sendMessage(
            text: "hello",
            session: session,
            modelId: "claude-test",
            modelContext: modelContext
        )

        await waitUntil {
            copilot.deactivatedSessionIDs == [session.sessionId] && openCode.sentTexts == ["hello"]
        }

        #expect(copilot.deactivatedSessionIDs == [session.sessionId])
        #expect(openCode.sentTexts == ["hello"])
    }

    @Test func claudeServiceReleasesExternalACPProviderFromOtherSessionBeforeSwitchingProviders() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        let sessionA = Session.fixture(title: "Session A")
        sessionA.defaultExecutionProviderID = ConversationExecutionProviderID.openCodeCLI.rawValue
        let sessionB = Session.fixture(title: "Session B")
        sessionB.defaultExecutionProviderID = ConversationExecutionProviderID.githubCopilotCLI.rawValue
        modelContext.insert(settings)
        modelContext.insert(sessionA)
        modelContext.insert(sessionB)
        try modelContext.save()

        let harness = ExternalACPConflictHarness()
        let builtIn = ProviderSpy(id: .builtInAgent)
        let copilot = ProviderSpy(id: .githubCopilotCLI, runtimeScope: .externalACP, conflictHarness: harness)
        let openCode = ProviderSpy(id: .openCodeCLI, runtimeScope: .externalACP, conflictHarness: harness)
        let claudeService = ClaudeService()
        claudeService.executionProviderRegistry = ConversationExecutionProviderRegistry(
            builtIn: builtIn,
            copilot: copilot,
            openCode: openCode
        )

        try await claudeService.sendMessage(
            text: "open first",
            session: sessionA,
            modelId: "test-model",
            modelContext: modelContext
        )

        try await claudeService.sendMessage(
            text: "copilot second",
            session: sessionB,
            modelId: "test-model",
            modelContext: modelContext
        )

        await waitUntil {
            openCode.deactivatedSessionIDs == [sessionA.sessionId] && copilot.sentTexts == ["copilot second"]
        }

        #expect(openCode.deactivatedSessionIDs == [sessionA.sessionId])
        #expect(copilot.sentTexts == ["copilot second"])
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ExecutionJob.self,
            ExecutionAttempt.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while !condition() && ContinuousClock.now < deadline {
        await Task.yield()
    }
}

@MainActor
private final class ProviderSpy: ConversationExecutionProvider {
    let id: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope?
    let conflictHarness: ExternalACPConflictHarness?
    private(set) var sentTexts: [String] = []
    private(set) var resetSessionIDs: [String] = []
    private(set) var deactivatedSessionIDs: [String] = []
    private var activeSessionIDs: Set<String> = []

    init(
        id: ConversationExecutionProviderID,
        runtimeScope: ConversationExecutionRuntimeScope? = nil,
        conflictHarness: ExternalACPConflictHarness? = nil
    ) {
        self.id = id
        self.runtimeScope = runtimeScope
        self.conflictHarness = conflictHarness
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        if let conflictHarness, let scope = runtimeScope, scope == .externalACP {
            try conflictHarness.activate(providerID: id, sessionID: request.session.sessionId)
            activeSessionIDs.insert(request.session.sessionId)
        }
        if let targetAgentMessageID = request.targetAgentMessageID,
           let targetMessage = request.session.messages.first(where: { $0.id == targetAgentMessageID }) {
            targetMessage.status = .completed
            if targetMessage.textContent?.isEmpty ?? true {
                targetMessage.textContent = sentTexts.isEmpty ? request.text : "\(request.text)-done"
            }
        }
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

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        _ = modelContext
        resetSessionIDs.append(session.sessionId)
        if activeSessionIDs.remove(session.sessionId) != nil {
            deactivatedSessionIDs.append(session.sessionId)
            conflictHarness?.deactivate(providerID: id, sessionID: session.sessionId)
        }
    }

    func prepareForActivation(
        session: Session,
        isActiveProvider: Bool,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async {
        _ = modelContext
        _ = trigger
        guard runtimeScope == .externalACP else { return }

        let sessionIDsToDeactivate: [String]
        if isActiveProvider {
            sessionIDsToDeactivate = activeSessionIDs.filter { $0 != session.sessionId }
        } else {
            sessionIDsToDeactivate = Array(activeSessionIDs)
        }

        for sessionID in sessionIDsToDeactivate.sorted() {
            activeSessionIDs.remove(sessionID)
            deactivatedSessionIDs.append(sessionID)
            conflictHarness?.deactivate(providerID: id, sessionID: sessionID)
        }
    }
}

private final class ExternalACPConflictHarness {
    private var activeLease: (providerID: ConversationExecutionProviderID, sessionID: String)?

    func activate(providerID: ConversationExecutionProviderID, sessionID: String) throws {
        if let activeLease,
           activeLease.providerID != providerID || activeLease.sessionID != sessionID {
            throw ExternalACPConflictError.conflict(
                currentProviderID: activeLease.providerID,
                currentSessionID: activeLease.sessionID,
                requestedProviderID: providerID,
                requestedSessionID: sessionID
            )
        }

        activeLease = (providerID, sessionID)
    }

    func deactivate(providerID: ConversationExecutionProviderID, sessionID: String) {
        guard let activeLease,
              activeLease.providerID == providerID,
              activeLease.sessionID == sessionID else {
            return
        }

        self.activeLease = nil
    }
}

private enum ExternalACPConflictError: Error {
    case conflict(
        currentProviderID: ConversationExecutionProviderID,
        currentSessionID: String,
        requestedProviderID: ConversationExecutionProviderID,
        requestedSessionID: String
    )
}