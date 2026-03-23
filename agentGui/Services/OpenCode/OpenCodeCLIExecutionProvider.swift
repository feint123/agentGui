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

@MainActor
protocol OpenCodeCLIRuntimeClient: ACPExternalProviderRuntimeClient, ACPExternalProviderRuntimeTransportClient {}

extension ACPExternalAgentRuntimeClient: OpenCodeCLIRuntimeClient {}

typealias OpenCodeCLIRuntimeClientFactory = @MainActor (
    ACPExternalAgentLaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) throws -> any OpenCodeCLIRuntimeClient

@MainActor
final class OpenCodeCLIExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    private let runtimeFactory: OpenCodeCLIRuntimeFactory
    private let availabilityService: OpenCodeCLIAvailabilityService
    private let runtimeClientFactory: OpenCodeCLIRuntimeClientFactory

    init(
        runtimeFactory: OpenCodeCLIRuntimeFactory = OpenCodeCLIRuntimeFactory(),
        availabilityService: OpenCodeCLIAvailabilityService = OpenCodeCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void = { _ in },
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

    override func selectedModelOverride(
        for configuration: ACPCLIConfiguration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> String? {
        handshake.capabilities.supportsSessionModelOverride ? trimmedNonEmpty(configuration.defaultModel) : nil
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