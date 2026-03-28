import Foundation
import SwiftData

typealias DynamicACPRuntimeClientFactory = @Sendable (
    ACPExternalAgentLaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) async throws -> any ACPExternalProviderRuntimeTransportClient

@MainActor
final class DynamicACPExternalExecutionProvider: ACPExternalExecutionProviderBase<ACPProviderProfile> {
    let profile: ACPProviderProfile

    private let runtimeClientFactory: DynamicACPRuntimeClientFactory

    init(
        profile: ACPProviderProfile,
        terminalRuntimeFactory: @escaping ACPExternalTerminalRuntimeFactory,
        sessionRuntimeResetter: @escaping ACPExternalSessionRuntimeResetter = { _ in },
        permissionCenter: ACPPermissionCenter,
        runtimeClientFactory: @escaping DynamicACPRuntimeClientFactory = { launchConfiguration, terminalRuntime, authorizationPolicy, permissionResolver, updateSink in
            try ACPExternalAgentRuntimeClient(
                launchConfiguration: launchConfiguration,
                terminalRuntime: terminalRuntime,
                authorizationPolicy: authorizationPolicy,
                permissionResolver: permissionResolver,
                eventSink: updateSink
            )
        }
    ) {
        self.profile = profile
        self.runtimeClientFactory = runtimeClientFactory
        super.init(
            providerReference: .externalACP(profileID: profile.id),
            providerDisplayName: profile.displayName,
            terminalRuntimeFactory: terminalRuntimeFactory,
            sessionRuntimeResetter: sessionRuntimeResetter,
            permissionCenter: permissionCenter,
            authorizationPolicyFactory: ConversationAuthorizationPolicyFactory(),
            featureAdapter: ACPExternalProviderFeatureAdapter()
        )
    }

    override func resolveConfiguration(for session: Session, settings: AppSettings) -> ACPProviderProfile {
        _ = session
        _ = settings
        return profile
    }

    override func useACPStdIO(configuration: ACPProviderProfile) -> Bool {
        configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    override func unsupportedConfigurationError() -> Error {
        DynamicACPExternalExecutionProviderError.unsupportedConfiguration
    }

    override func quickAvailabilityStatus(configuration: ACPProviderProfile) -> ACPCLIAvailabilityStatus {
        let executablePath = configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard executablePath.isEmpty == false else {
            return ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: configuration.displayName)
        }
        return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: configuration.displayName)
    }

    override func unavailableError(summary: String) -> Error {
        DynamicACPExternalExecutionProviderError.unavailable(summary)
    }

    override func approvalMode(for configuration: ACPProviderProfile) -> ToolApprovalMode {
        _ = configuration
        return GitHubCopilotCLIApprovalModeOption.resolved(
            from: ACPCLIConfiguration.externalProviderDefaultApprovalMode
        ) == .bypassApprovals ? .bypassApprovals : .defaultApprovals
    }

    override nonisolated func buildRuntimeClient(
        configuration: ACPProviderProfile,
        localSessionID: String,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        let launchConfiguration = ACPExternalAgentLaunchConfiguration(
            command: configuration.executablePath,
            arguments: configuration.arguments,
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        )
        let terminalRuntime = await makeTerminalRuntime(sessionID: localSessionID, workingDirectory: workingDirectory)
        return try await runtimeClientFactory(
            launchConfiguration,
            terminalRuntime,
            authorizationPolicy,
            permissionResolver,
            updateSink
        )
    }

    override func initialSessionConfigSelections(
        for session: Session,
        configuration: ACPProviderProfile,
        handshake: ACPExternalAgentSessionHandshake
    ) -> [ACPExternalSessionConfigSelection] {
        _ = configuration

        guard let snapshot = session.executionPreferences.externalACP[profile.id] else {
            return []
        }

        return handshake.configurationSnapshot.configOptions.compactMap { option in
            guard let normalizedID = option.normalizedID,
                  let selectedValue = snapshot.selectedValuesByConfigID[normalizedID],
                  selectedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }

            return ACPExternalSessionConfigSelection(
                configID: normalizedID,
                value: selectedValue,
                category: option.category
            )
        }
    }

    override func initialSessionModeID(
        for session: Session,
        handshake: ACPExternalAgentSessionHandshake
    ) -> String? {
        let selectedModeID = session.executionPreferences.externalACP[profile.id]?.selectedModeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedModeID, selectedModeID.isEmpty == false else {
            return nil
        }

        let availableModeIDs = Set(handshake.configurationSnapshot.modes?.availableModes.map(\.id) ?? [])
        guard availableModeIDs.contains(selectedModeID) else {
            return nil
        }

        return selectedModeID
    }
}

enum DynamicACPExternalExecutionProviderError: LocalizedError {
    case unsupportedConfiguration
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration:
            return "当前动态 ACP Provider 缺少可用的可执行路径。"
        case .unavailable(let summary):
            return summary
        }
    }
}