import Foundation
import Observation

@MainActor
@Observable
final class ChatExecutionProviderAvailabilityModel {
    @ObservationIgnored private let probe: @Sendable (ConversationExecutionProviderID, String) async -> ACPCLIAvailabilityStatus

    var copilotStatus: ACPCLIAvailabilityStatus = .unknown
    var openCodeStatus: ACPCLIAvailabilityStatus = .unknown

    init(
        probe: @escaping @Sendable (ConversationExecutionProviderID, String) async -> ACPCLIAvailabilityStatus = ChatExecutionProviderAvailabilityModel.defaultProbe
    ) {
        self.probe = probe
    }

    func refreshStatus(for providerID: ConversationExecutionProviderID, executablePath: String) async {
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
        case .builtInAgent:
            break
        }
    }

    func refreshCopilotStatus(configuration: ACPCLIConfiguration) async {
        await refreshStatus(for: .githubCopilotCLI, executablePath: configuration.executablePath)
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
            case .builtInAgent:
                return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: "内置 Agent")
            }
        } catch {
            return ACPCLIAvailabilityStatus(kind: .failed(error.localizedDescription), version: nil)
        }
    }
}