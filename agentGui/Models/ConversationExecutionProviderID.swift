import Foundation

enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"

    var displayName: String {
        switch self {
        case .builtInAgent:
            return "内置 Agent"
        case .githubCopilotCLI:
            return "GitHub Copilot CLI"
        case .openCodeCLI:
            return "OpenCode"
        }
    }

    static func optionItems(
        copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus = .unknown,
        openCodeAvailabilityStatus: OpenCodeCLIAvailabilityStatus = .unknown
    ) -> [ExecutionOptionItem] {
        allCases.map { provider in
            let isEnabled: Bool
            switch provider {
            case .builtInAgent:
                isEnabled = true
            case .githubCopilotCLI:
                isEnabled = copilotAvailabilityStatus.kind == .available
            case .openCodeCLI:
                isEnabled = openCodeAvailabilityStatus.kind == .available
            }

            return ExecutionOptionItem(
                id: provider.rawValue,
                title: provider.displayName,
                isEnabled: isEnabled
            )
        }
    }
}