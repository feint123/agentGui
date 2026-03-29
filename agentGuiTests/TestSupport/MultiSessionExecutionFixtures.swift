import Foundation
import SwiftData
@testable import agentGui

@MainActor
final class SessionRuntimeResetTracker {
    private(set) var resetSessionIDs: [String] = []

    func record(_ sessionID: String) {
        resetSessionIDs.append(sessionID)
    }
}

@MainActor
final class UnavailableACPTestExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    init(sessionRuntimeResetter: @escaping ACPExternalSessionRuntimeResetter = { _ in }) {
        super.init(
            providerReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference,
            providerDisplayName: ConversationExecutionProviderID.githubCopilotCLI.displayName,
            legacyProviderID: .githubCopilotCLI,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: ACPPermissionCenter(),
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory(),
            featureAdapter: .gitHubCopilot
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        .init(
            executablePath: "/definitely-missing-acp-binary",
            defaultModel: "",
            defaultApprovalMode: ACPCLIConfiguration.externalProviderDefaultApprovalMode
        )
    }

    override func useACPStdIO(configuration: ACPCLIConfiguration) -> Bool {
        true
    }

    override func unsupportedConfigurationError() -> Error {
        TestProviderError.unsupported
    }

    override func quickAvailabilityStatus(configuration: ACPCLIConfiguration) -> ACPCLIAvailabilityStatus {
        ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: "Test ACP")
    }

    override func unavailableError(summary: String) -> Error {
        TestProviderError.unavailable(summary)
    }

    override func approvalMode(for configuration: ACPCLIConfiguration) -> ToolApprovalMode {
        .defaultApprovals
    }

    override nonisolated func buildRuntimeClient(
        configuration: ACPCLIConfiguration,
        localSessionID: String,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        _ = localSessionID
        fatalError("UnavailableACPTestExecutionProvider should not build a runtime client in this test path")
    }

    override func initialSessionConfigSelections(
        for session: Session,
        configuration: ACPCLIConfiguration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> [ACPExternalSessionConfigSelection] {
        _ = session
        _ = configuration
        _ = handshake
        return []
    }
}

enum TestProviderError: Error, Equatable {
    case unsupported
    case unavailable(String)
}

enum MultiSessionExecutionFixtureFactory {
    @MainActor
    static func makeProviderActivationHarness(
        runtimeStateStore: SessionExecutionRuntimeStateStore? = nil,
        projectionStore: ExecutionProjectionStore? = nil
    ) throws -> (context: ModelContext, firstSession: Session, secondSession: Session, projectionStore: ExecutionProjectionStore) {
        _ = runtimeStateStore
        let projectionStore = projectionStore ?? ExecutionProjectionStore()
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()
        let secondSession = Session.fixture(sessionId: "multi-session-b", title: "Session B")
        harness.context.insert(secondSession)
        try harness.context.save()
        return (harness.context, harness.session, secondSession, projectionStore)
    }

    @MainActor
    static func extractRuntimeSupervisor(from provider: AnyObject) -> ACPProviderRuntimeSupervisor? {
        var currentMirror: Mirror? = Mirror(reflecting: provider)
        while let mirror = currentMirror {
            for child in mirror.children {
                if let supervisor = child.value as? ACPProviderRuntimeSupervisor {
                    return supervisor
                }
            }
            currentMirror = mirror.superclassMirror
        }
        return nil
    }
}