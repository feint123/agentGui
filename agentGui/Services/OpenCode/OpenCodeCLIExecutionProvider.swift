import Foundation
import SwiftData

enum OpenCodeCLIExecutionProviderError: LocalizedError {
    case unavailable(String)
    case unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .unsupportedConfiguration:
            return "当前仅支持 OpenCode CLI 的 ACP stdio 模式。"
        }
    }
}

protocol OpenCodeCLIRuntimeClient: ACPExternalProviderRuntimeClient, ACPExternalProviderRuntimeTransportClient {}

extension ACPExternalAgentRuntimeClient: OpenCodeCLIRuntimeClient {}

typealias OpenCodeCLIRuntimeClientFactory = @Sendable (
    ACPExternalAgentLaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) throws -> any OpenCodeCLIRuntimeClient

@MainActor
final class OpenCodeCLIExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    nonisolated private let runtimeFactory: OpenCodeCLIRuntimeFactory
    private let availabilityService: OpenCodeCLIAvailabilityService
    nonisolated private let runtimeClientFactory: OpenCodeCLIRuntimeClientFactory

    init(
        runtimeFactory: OpenCodeCLIRuntimeFactory = OpenCodeCLIRuntimeFactory(),
        availabilityService: OpenCodeCLIAvailabilityService = OpenCodeCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping ACPExternalTerminalRuntimeFactory,
        sessionRuntimeResetter: @escaping ACPExternalSessionRuntimeResetter = { _ in },
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory = ConversationAuthorizationPolicyFactory(),
        runtimeClientFactory: @escaping OpenCodeCLIRuntimeClientFactory = OpenCodeCLIExecutionProvider.makeRuntimeClient
    ) {
        self.runtimeFactory = runtimeFactory
        self.availabilityService = availabilityService
        self.runtimeClientFactory = runtimeClientFactory
        super.init(
            providerID: .openCodeCLI,
            terminalRuntimeFactory: terminalRuntimeFactory,
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: permissionCenter,
            authorizationPolicyFactory: authorizationPolicyFactory,
            featureAdapter: .openCode
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        SessionExecutionPreferencesResolver.openCodeCLIConfiguration(for: session, settings: settings)
    }

    override func useACPStdIO(configuration: ACPCLIConfiguration) -> Bool {
        true
    }

    override func unsupportedConfigurationError() -> Error {
        OpenCodeCLIExecutionProviderError.unsupportedConfiguration
    }

    override func quickAvailabilityStatus(configuration: ACPCLIConfiguration) -> ACPCLIAvailabilityStatus {
        availabilityService.quickStatus(configuration: configuration)
    }

    override func unavailableError(summary: String) -> Error {
        OpenCodeCLIExecutionProviderError.unavailable(summary)
    }

    override func approvalMode(for configuration: ACPCLIConfiguration) -> ToolApprovalMode {
        ToolApprovalMode.resolved(from: configuration.defaultApprovalMode)
    }

    override nonisolated func buildRuntimeClient(
        configuration: ACPCLIConfiguration,
        localSessionID: String,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        let launchConfiguration = runtimeFactory.makeLaunchConfiguration(
            executablePath: configuration.executablePath,
            workingDirectory: workingDirectory
        )
        let terminalRuntime = await makeTerminalRuntime(sessionID: localSessionID, workingDirectory: workingDirectory)
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

        guard let modeID = session.executionPreferences.openCodeCLI.modeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modeID.isEmpty else {
            return nil
        }

        return modeID
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

    nonisolated private static func makeRuntimeClient(
        launchConfiguration: ACPExternalAgentLaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws -> any OpenCodeCLIRuntimeClient {
        try ACPExternalAgentRuntimeClient(
            launchConfiguration: launchConfiguration,
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
    }
}