import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPExternalExecutionProviderBaseTests {
    @Test func providerBaseNoLongerOwnsSessionLiveState() {
        let probe = ACPExternalExecutionProviderBaseProbe(
            providerID: .githubCopilotCLI,
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
        ProbeRuntimeClient()
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
    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        ACPExternalAgentCapabilitySnapshot(loadSession: false, supportsSessionModelOverride: false, agentVersion: nil)
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        ACPExternalAgentSessionHandshake(
            remoteSessionID: "probe-remote",
            capabilities: ACPExternalAgentCapabilitySnapshot(loadSession: false, supportsSessionModelOverride: false, agentVersion: nil)
        )
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {}

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        []
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        .endTurn
    }

    func cancel(sessionID: String) async throws {}

    func close() async {}
}
