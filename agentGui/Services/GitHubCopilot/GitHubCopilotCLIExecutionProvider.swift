import Foundation
import SwiftData

enum GitHubCopilotCLIExecutionProviderError: LocalizedError {
    case unavailable(String)
    case unsupportedConfiguration
    case sessionAlreadyAttached(current: String, requested: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .unsupportedConfiguration:
            return "当前仅支持 GitHub Copilot CLI 的 ACP stdio 模式。"
        case .sessionAlreadyAttached(let current, let requested):
            return "当前 Copilot 运行时已绑定会话 \(current)，不能在同一运行时内切换到 \(requested)。"
        }
    }
}

typealias GitHubCopilotCLISessionHandshake = ACPExternalAgentSessionHandshake

extension ACPExternalAgentSessionHandshake {
    init(remoteSessionID: String, cliVersion: String?) {
        self.init(
            remoteSessionID: remoteSessionID,
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: cliVersion
            )
        )
    }

    var cliVersion: String? {
        capabilities.agentVersion
    }
}

@MainActor
protocol GitHubCopilotCLIRuntimeClient: ACPExternalProviderRuntimeClient, ACPExternalProviderRuntimeTransportClient {}

extension ACPExternalAgentRuntimeClient: GitHubCopilotCLIRuntimeClient {}

typealias GitHubCopilotCLIRuntimeClientFactory = @MainActor (
    GitHubCopilotCLILaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) throws -> any GitHubCopilotCLIRuntimeClient

@MainActor
final class GitHubCopilotCLIExecutionProvider: ACPExternalExecutionProviderBase<ACPCLIConfiguration> {
    private let runtimeFactory: GitHubCopilotCLIRuntimeFactory
    private let availabilityService: GitHubCopilotCLIAvailabilityService
    private let runtimeClientFactory: GitHubCopilotCLIRuntimeClientFactory

    init(
        runtimeFactory: GitHubCopilotCLIRuntimeFactory = GitHubCopilotCLIRuntimeFactory(),
        availabilityService: GitHubCopilotCLIAvailabilityService = GitHubCopilotCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void = { _ in },
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory = ConversationAuthorizationPolicyFactory(),
        runtimeClientFactory: @escaping GitHubCopilotCLIRuntimeClientFactory = GitHubCopilotCLIExecutionProvider.makeRuntimeClient
    ) {
        self.runtimeFactory = runtimeFactory
        self.availabilityService = availabilityService
        self.runtimeClientFactory = runtimeClientFactory
        super.init(
            providerID: .githubCopilotCLI,
            terminalRuntimeFactory: terminalRuntimeFactory,
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: permissionCenter,
            authorizationPolicyFactory: authorizationPolicyFactory,
            featureAdapter: .gitHubCopilot
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        SessionExecutionPreferencesResolver.gitHubCopilotCLIConfiguration(for: session, settings: settings)
    }

    override func useACPStdIO(configuration: ACPCLIConfiguration) -> Bool {
        true
    }

    override func unsupportedConfigurationError() -> Error {
        GitHubCopilotCLIExecutionProviderError.unsupportedConfiguration
    }

    override func quickAvailabilityStatus(configuration: ACPCLIConfiguration) -> ACPCLIAvailabilityStatus {
        availabilityService.quickStatus(configuration: configuration)
    }

    override func unavailableError(summary: String) -> Error {
        GitHubCopilotCLIExecutionProviderError.unavailable(summary)
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
        configuration.defaultModel.nonEmptyValue
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
        launchConfiguration: GitHubCopilotCLILaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws -> any GitHubCopilotCLIRuntimeClient {
        try ACPExternalAgentRuntimeClient(
            launchConfiguration: launchConfiguration,
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            supportsSessionModelOverrideFallback: true,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}