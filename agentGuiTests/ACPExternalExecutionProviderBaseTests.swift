import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPExternalExecutionProviderBaseTests {
    @Test func providerBaseNoLongerOwnsSessionLiveState() {
        let probe = ACPExternalExecutionProviderBaseProbe(
            providerID: .githubCopilotCLI,
            runtimeClient: ProbeRuntimeClient(),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            sessionRuntimeResetter: { _ in },
            permissionCenter: ACPPermissionCenter(),
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory()
        )

        var labels = Set<String>()
        var currentMirror: Mirror? = Mirror(reflecting: probe)
        while let mirror = currentMirror {
            labels.formUnion(mirror.children.compactMap(\.label))
            currentMirror = mirror.superclassMirror
        }

        #expect(labels.contains("runtimeClients") == false)
        #expect(labels.contains("runtimeActivationIDs") == false)
        #expect(labels.contains("runtimeWorkingDirectories") == false)
        #expect(labels.contains("activeTurns") == false)
        #expect(labels.contains("featureStores") == false)
        #expect(labels.contains("remoteSessionIDs") == false)
        #expect(labels.contains("sessionContexts") == false)
        #expect(labels.contains("pendingUpdateTasks") == false)
        #expect(labels.contains("pendingUpdateTaskTokens") == false)
    }

    @Test func sessionConfigurationUpdatesKeepSelectedModeWhenModelChangesAfterward() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = ACPCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "gpt-5",
            defaultApprovalMode: "default",
            environment: [:],
            useACPStdIO: true
        )
        let session = Session.fixture(title: "ACP Sticky Mode")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = ProbeRuntimeClient(
            handshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "probe-remote",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                ),
                configurationSnapshot: configuredSessionSnapshot(currentModel: "gpt-5", currentModeID: "plan")
            ),
            sessionConfigOptionResults: [
                "model": configuredSessionSnapshot(currentModel: "gpt-5-mini", currentModeID: "plan").configOptions
            ]
        )
        let probe = ACPExternalExecutionProviderBaseProbe(
            providerID: .githubCopilotCLI,
            runtimeClient: runtimeClient,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            sessionRuntimeResetter: { _ in },
            permissionCenter: ACPPermissionCenter(),
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory()
        )

        try await probe.updateSessionMode(session: session, modelContext: modelContext, modeID: "edit")
        try await probe.updateSessionConfigOption(session: session, modelContext: modelContext, configID: "model", value: "gpt-5-mini")

        let snapshot = try #require(probe.remoteSessionConfiguration(localSessionID: session.sessionId))
        #expect(snapshot.modes?.currentModeID == "edit")
        #expect(snapshot.modelConfigOption?.currentValue == "gpt-5-mini")
    }

    @Test func sessionConfigurationUpdatesKeepSelectedModelWhenModeChangesAfterward() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = ACPCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "gpt-5",
            defaultApprovalMode: "default",
            environment: [:],
            useACPStdIO: true
        )
        let session = Session.fixture(title: "ACP Sticky Model")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = ProbeRuntimeClient(
            handshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "probe-remote",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                ),
                configurationSnapshot: configuredSessionSnapshot(currentModel: "gpt-5", currentModeID: "plan")
            ),
            sessionConfigOptionResults: [
                "model": configuredSessionSnapshot(currentModel: "gpt-5-mini", currentModeID: "plan").configOptions
            ]
        )
        let probe = ACPExternalExecutionProviderBaseProbe(
            providerID: .githubCopilotCLI,
            runtimeClient: runtimeClient,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            sessionRuntimeResetter: { _ in },
            permissionCenter: ACPPermissionCenter(),
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory()
        )

        try await probe.updateSessionConfigOption(session: session, modelContext: modelContext, configID: "model", value: "gpt-5-mini")
        try await probe.updateSessionMode(session: session, modelContext: modelContext, modeID: "edit")

        let snapshot = try #require(probe.remoteSessionConfiguration(localSessionID: session.sessionId))
        #expect(snapshot.modes?.currentModeID == "edit")
        #expect(snapshot.modelConfigOption?.currentValue == "gpt-5-mini")
    }

    @Test func restoredSessionReappliesLatestHandshakeConfigurationForSameRemoteSession() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = ACPCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "gpt-5",
            defaultApprovalMode: "default",
            environment: [:],
            useACPStdIO: true
        )
        let session = Session.fixture(title: "ACP Restored Configuration")
        session.workingDirectory = "/tmp/agentGui-acp-initial"
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let initialHandshake = ACPExternalAgentSessionHandshake(
            remoteSessionID: "probe-remote",
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            configurationSnapshot: configuredSessionSnapshot(currentModel: "gpt-5", currentModeID: "plan")
        )
        let restoredHandshake = ACPExternalAgentSessionHandshake(
            remoteSessionID: "probe-remote",
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            configurationSnapshot: configuredSessionSnapshot(currentModel: "gpt-5-mini", currentModeID: "edit")
        )
        let runtimeClient = ProbeRuntimeClient(
            handshake: initialHandshake,
            loadSessionHandshakes: [restoredHandshake]
        )
        let probe = ACPExternalExecutionProviderBaseProbe(
            providerID: .githubCopilotCLI,
            runtimeClient: runtimeClient,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            sessionRuntimeResetter: { _ in },
            permissionCenter: ACPPermissionCenter(),
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory()
        )

        await probe.prepareForActivation(
            session: session,
            isActiveProvider: true,
            modelContext: modelContext,
            trigger: .selection
        )

        let initialSnapshot = try #require(probe.remoteSessionConfiguration(localSessionID: session.sessionId))
        #expect(initialSnapshot.modes?.currentModeID == "plan")
        #expect(initialSnapshot.modelConfigOption?.currentValue == "gpt-5")

        await probe.prepareForActivation(
            session: session,
            isActiveProvider: false,
            modelContext: modelContext,
            trigger: .selection
        )
        session.workingDirectory = "/tmp/agentGui-acp-restored"
        try modelContext.save()

        await probe.prepareForActivation(
            session: session,
            isActiveProvider: true,
            modelContext: modelContext,
            trigger: .selection
        )

        let restoredSnapshot = try #require(probe.remoteSessionConfiguration(localSessionID: session.sessionId))
        #expect(restoredSnapshot.modes?.currentModeID == "edit")
        #expect(restoredSnapshot.modelConfigOption?.currentValue == "gpt-5-mini")
    }

    private func makeModelContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            ACPExternalSessionBinding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func configuredSessionSnapshot(
        currentModel: String,
        currentModeID: String
    ) -> ACPExternalAgentSessionConfigurationSnapshot {
        ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: [
                ACPSessionConfigOption(
                    meta: nil,
                    id: "model",
                    category: .model,
                    currentValue: currentModel,
                    options: .ungrouped([
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT-5", value: "gpt-5"),
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT-5 Mini", value: "gpt-5-mini")
                    ]),
                    type: "select"
                )
            ],
            modes: ACPSessionModeState(
                meta: nil,
                availableModes: [
                    ACPSessionMode(meta: nil, description: nil, id: "plan", name: "Plan"),
                    ACPSessionMode(meta: nil, description: nil, id: "edit", name: "Edit")
                ],
                currentModeID: currentModeID
            )
        )
    }
}

enum ExternalACPProviderAssertionHelpers {
    static func expectLiveTurnProjection(
        assistantMessage: Message,
        toolCalls: [ToolCall],
        expectedText: String,
        expectedToolCallID: String,
        expectedToolTitle: String,
        expectedToolOutput: String
    ) {
        #expect(assistantMessage.textContent == expectedText)
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.toolCallId == expectedToolCallID)
        #expect(toolCalls.first?.title == expectedToolTitle)
        #expect(toolCalls.first?.terminalOutput == expectedToolOutput)
    }

    static func expectCancelledMessageSettlesToolCalls(_ message: Message) {
        #expect(message.status == .cancelled)

        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }
        let allToolCalls = roundCalls + directCalls

        #expect(allToolCalls.allSatisfy { $0.status != .inProgress })
    }
}

@MainActor
private final class ACPExternalExecutionProviderBaseProbe: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    private let runtimeClient: ProbeRuntimeClient

    init(
        providerID: ConversationExecutionProviderID,
        runtimeClient: ProbeRuntimeClient,
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void,
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory
    ) {
        self.runtimeClient = runtimeClient
        super.init(
            providerID: providerID,
            terminalRuntimeFactory: terminalRuntimeFactory,
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: permissionCenter,
            authorizationPolicyFactory: authorizationPolicyFactory
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        settings.githubCopilotCLIConfiguration
    }

    override func useACPStdIO(configuration: ACPCLIConfiguration) -> Bool {
        true
    }

    override func unsupportedConfigurationError() -> Error {
        CancellationError()
    }

    override func quickAvailabilityStatus(configuration: ACPCLIConfiguration) -> ACPCLIAvailabilityStatus {
        ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: "Probe")
    }

    override func unavailableError(summary: String) -> Error {
        NSError(domain: "ACPExternalExecutionProviderBaseProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: summary])
    }

    override func approvalMode(for configuration: ACPCLIConfiguration) -> ToolApprovalMode {
        .defaultApprovals
    }

    override func buildRuntimeClient(
        configuration: ACPCLIConfiguration,
        session: Session,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        runtimeClient.updateSink = updateSink
        return runtimeClient
    }

    override func initialSessionConfigSelections(
        for configuration: ACPCLIConfiguration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> [ACPExternalSessionConfigSelection] {
        []
    }
}

@MainActor
private final class ProbeRuntimeClient: ACPExternalProviderRuntimeTransportClient {
    let handshake: ACPExternalAgentSessionHandshake
    let sessionConfigOptionResults: [String: [ACPSessionConfigOption]]
    private var loadSessionHandshakes: [ACPExternalAgentSessionHandshake?]
    private var createSessionHandshakes: [ACPExternalAgentSessionHandshake]

    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?

    init(
        handshake: ACPExternalAgentSessionHandshake = ACPExternalAgentSessionHandshake(
            remoteSessionID: "probe-remote",
            capabilities: ACPExternalAgentCapabilitySnapshot(loadSession: false, supportsSessionModelOverride: false, agentVersion: nil)
        ),
        sessionConfigOptionResults: [String: [ACPSessionConfigOption]] = [:],
        loadSessionHandshakes: [ACPExternalAgentSessionHandshake?] = [],
        createSessionHandshakes: [ACPExternalAgentSessionHandshake] = []
    ) {
        self.handshake = handshake
        self.sessionConfigOptionResults = sessionConfigOptionResults
        self.loadSessionHandshakes = loadSessionHandshakes
        self.createSessionHandshakes = createSessionHandshakes
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        handshake.capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        _ = workingDirectory
        _ = remoteSessionID
        if loadSessionHandshakes.isEmpty == false {
            return loadSessionHandshakes.removeFirst()
        }
        return handshake.capabilities.loadSession ? handshake : nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        _ = workingDirectory
        if createSessionHandshakes.isEmpty == false {
            return createSessionHandshakes.removeFirst()
        }
        return handshake
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {}

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        _ = value
        _ = sessionID
        return sessionConfigOptionResults[configID] ?? []
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        .endTurn
    }

    func cancel(sessionID: String) async throws {}

    func close() async {}
}
