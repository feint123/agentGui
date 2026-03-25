import Foundation
import SwiftData

enum ClaudeAdapterCLIExecutionProviderError: LocalizedError {
    case unavailable(String)
    case unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .unsupportedConfiguration:
            return "当前仅支持 Claude adapter CLI 的 ACP stdio 模式。"
        }
    }
}

@MainActor
protocol ClaudeAdapterCLIRuntimeClient: ACPExternalProviderRuntimeClient, ACPExternalProviderRuntimeTransportClient {}

extension ACPExternalAgentRuntimeClient: ClaudeAdapterCLIRuntimeClient {}

typealias ClaudeAdapterCLIRuntimeClientFactory = @MainActor (
    ACPExternalAgentLaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) throws -> any ClaudeAdapterCLIRuntimeClient

@MainActor
final class ClaudeAdapterCLIExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    private let runtimeFactory: ClaudeAdapterCLIRuntimeFactory
    private let availabilityService: ClaudeAdapterCLIAvailabilityService
    private let runtimeClientFactory: ClaudeAdapterCLIRuntimeClientFactory

    init(
        runtimeFactory: ClaudeAdapterCLIRuntimeFactory = ClaudeAdapterCLIRuntimeFactory(),
        availabilityService: ClaudeAdapterCLIAvailabilityService = ClaudeAdapterCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void = { _ in },
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory = ConversationAuthorizationPolicyFactory(),
        runtimeClientFactory: @escaping ClaudeAdapterCLIRuntimeClientFactory = ClaudeAdapterCLIExecutionProvider.makeRuntimeClient
    ) {
        self.runtimeFactory = runtimeFactory
        self.availabilityService = availabilityService
        self.runtimeClientFactory = runtimeClientFactory
        super.init(
            providerID: .claudeAdapterCLI,
            terminalRuntimeFactory: terminalRuntimeFactory,
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: permissionCenter,
            authorizationPolicyFactory: authorizationPolicyFactory,
            featureAdapter: ACPExternalProviderFeatureAdapter()
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        SessionExecutionPreferencesResolver.claudeAdapterCLIConfiguration(for: session, settings: settings)
    }

    override func useACPStdIO(configuration: ACPCLIConfiguration) -> Bool {
        true
    }

    override func unsupportedConfigurationError() -> Error {
        ClaudeAdapterCLIExecutionProviderError.unsupportedConfiguration
    }

    override func quickAvailabilityStatus(configuration: ACPCLIConfiguration) -> ACPCLIAvailabilityStatus {
        availabilityService.quickStatus(configuration: configuration)
    }

    override func unavailableError(summary: String) -> Error {
        ClaudeAdapterCLIExecutionProviderError.unavailable(summary)
    }

    override func approvalMode(for configuration: ACPCLIConfiguration) -> ToolApprovalMode {
        ToolApprovalMode.resolved(from: configuration.defaultApprovalMode)
    }

    override func buildRuntimeClient(
        configuration: ACPCLIConfiguration,
        session: Session,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        let launchConfiguration = runtimeFactory.makeLaunchConfiguration(
            executablePath: configuration.executablePath,
            workingDirectory: workingDirectory
        )
        let terminalRuntime = makeTerminalRuntime(sessionID: session.sessionId, workingDirectory: workingDirectory)
        return try runtimeClientFactory(
            launchConfiguration,
            terminalRuntime,
            authorizationPolicy,
            permissionResolver,
            updateSink
        )
    }

    override func initialSessionConfigSelections(
        for configuration: ACPCLIConfiguration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> [ACPExternalSessionConfigSelection] {
        var selections: [ACPExternalSessionConfigSelection] = []

        if let modelValue = trimmedNonEmpty(configuration.defaultModel),
           let modelConfigID = handshake.configurationSnapshot.modelConfigOption?.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelConfigID.isEmpty {
            selections.append(
                ACPExternalSessionConfigSelection(
                    configID: modelConfigID,
                    value: modelValue,
                    category: .model
                )
            )
        }

        if let approvalConfigID = handshake.configurationSnapshot.approvalConfigOption?.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !approvalConfigID.isEmpty {
            selections.append(
                ACPExternalSessionConfigSelection(
                    configID: approvalConfigID,
                    value: GitHubCopilotCLIApprovalModeOption.resolved(from: configuration.defaultApprovalMode).rawValue,
                    category: handshake.configurationSnapshot.approvalConfigOption?.category
                )
            )
        }

        return selections
    }

    override func initialSessionModeID(
        for session: Session,
        handshake: ACPExternalAgentSessionHandshake
    ) -> String? {
        guard handshake.configurationSnapshot.modes != nil else {
            return nil
        }

        return trimmedNonEmpty(session.executionPreferences.claudeAdapterCLI.modeID ?? "")
    }

    override func persistBinding(
        sessionID: String,
        remoteSessionID: String,
        configuration: ACPCLIConfiguration,
        handshake: ACPExternalAgentSessionHandshake,
        selectedModel: String?,
        modelContext: ModelContext
    ) async {
        await persistBindingRecord(
            sessionID: sessionID,
            remoteSessionID: remoteSessionID,
            capabilities: handshake.capabilities,
            selectedModel: selectedModel,
            selectedAgentName: nil,
            modelContext: modelContext
        )
    }

    private static func makeRuntimeClient(
        launchConfiguration: ACPExternalAgentLaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws -> any ClaudeAdapterCLIRuntimeClient {
        try ACPExternalAgentRuntimeClient(
            launchConfiguration: launchConfiguration,
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}