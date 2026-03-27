import Foundation
import Observation

@MainActor
@Observable
final class ChatExecutionProviderAvailabilityModel {
    @ObservationIgnored private let probe: @Sendable (ConversationExecutionProviderID, String) async -> ACPCLIAvailabilityStatus

    var copilotStatus: ACPCLIAvailabilityStatus = .unknown
    var openCodeStatus: ACPCLIAvailabilityStatus = .unknown
    var claudeAdapterStatus: ACPCLIAvailabilityStatus = .unknown
    var isRefreshingCopilotStatus = false
    var isRefreshingOpenCodeStatus = false
    var isRefreshingClaudeAdapterStatus = false

    init(
        probe: @escaping @Sendable (ConversationExecutionProviderID, String) async -> ACPCLIAvailabilityStatus = ChatExecutionProviderAvailabilityModel.defaultProbe
    ) {
        self.probe = probe
    }

    func refreshStatus(for providerReference: ExecutionProviderReference, executablePath: String) async {
        guard let providerID = providerReference.compatibilityProviderID else {
            return
        }

        await refreshStatus(for: providerID, executablePath: executablePath)
    }

    func status(for providerReference: ExecutionProviderReference) -> ACPCLIAvailabilityStatus? {
        guard let providerID = providerReference.compatibilityProviderID else {
            return nil
        }

        switch providerID {
        case .githubCopilotCLI:
            return copilotStatus
        case .openCodeCLI:
            return openCodeStatus
        case .claudeAdapterCLI:
            return claudeAdapterStatus
        case .builtInAgent:
            return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: "内置 Agent")
        }
    }

    func refreshStatus(for providerID: ConversationExecutionProviderID, executablePath: String) async {
        setRefreshing(true, for: providerID)
        defer { setRefreshing(false, for: providerID) }

        let status = await probe(providerID, executablePath)
        switch providerID {
        case .githubCopilotCLI:
            if copilotStatus != status {
                copilotStatus = status
            }
        case .openCodeCLI:
            if openCodeStatus != status {
                openCodeStatus = status
            }
        case .claudeAdapterCLI:
            if claudeAdapterStatus != status {
                claudeAdapterStatus = status
            }
        case .builtInAgent:
            break
        }
    }

    func refreshCopilotStatus(configuration: ACPCLIConfiguration) async {
        await refreshStatus(for: .githubCopilotCLI, executablePath: configuration.executablePath)
    }

    func refreshClaudeAdapterStatus(configuration: ACPCLIConfiguration) async {
        await refreshStatus(for: .claudeAdapterCLI, executablePath: configuration.executablePath)
    }

    private func setRefreshing(_ isRefreshing: Bool, for providerID: ConversationExecutionProviderID) {
        switch providerID {
        case .githubCopilotCLI:
            if isRefreshingCopilotStatus != isRefreshing {
                isRefreshingCopilotStatus = isRefreshing
            }
        case .openCodeCLI:
            if isRefreshingOpenCodeStatus != isRefreshing {
                isRefreshingOpenCodeStatus = isRefreshing
            }
        case .claudeAdapterCLI:
            if isRefreshingClaudeAdapterStatus != isRefreshing {
                isRefreshingClaudeAdapterStatus = isRefreshing
            }
        case .builtInAgent:
            break
        }
    }

    private static func defaultProbe(providerID: ConversationExecutionProviderID, executablePath: String) async -> ACPCLIAvailabilityStatus {
        do {
            switch providerID {
            case .githubCopilotCLI:
                return try await GitHubCopilotCLIAvailabilityService().checkStatus(
                    configuration: ACPCLIConfiguration(
                        executablePath: executablePath,
                        defaultModel: "",
                        defaultApprovalMode: "default"
                    )
                )
            case .openCodeCLI:
                return try await ACPCLIAvailabilityService().checkStatus(
                    executablePath: executablePath,
                    displayName: "OpenCode"
                )
            case .claudeAdapterCLI:
                return try await ACPCLIAvailabilityService().checkStatus(
                    executablePath: executablePath,
                    displayName: "Claude Code"
                )
            case .builtInAgent:
                return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: "内置 Agent")
            }
        } catch {
            return ACPCLIAvailabilityStatus(kind: .failed(error.localizedDescription), version: nil)
        }
    }
}