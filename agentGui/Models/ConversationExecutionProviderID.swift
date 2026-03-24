import Foundation

enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"
    case claudeAdapterCLI = "claude_adapter_cli"

    var displayName: String {
        switch self {
        case .builtInAgent:
            return "内置 Agent"
        case .githubCopilotCLI:
            return "GitHub Copilot CLI"
        case .openCodeCLI:
            return "OpenCode"
        case .claudeAdapterCLI:
            return "Claude Code"
        }
    }

    var defaultCharacterSkin: CharacterSkin {
        switch self {
        case .builtInAgent:
            return .coder
        case .githubCopilotCLI:
            return .detective
        case .openCodeCLI:
            return .robot
        case .claudeAdapterCLI:
            return .wizard
        }
    }

    static func optionItems(
        copilotAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus = .unknown,
        openCodeAvailabilityStatus: OpenCodeCLIAvailabilityStatus = .unknown,
        claudeAdapterAvailabilityStatus: ClaudeAdapterCLIAvailabilityStatus = .unknown
    ) -> [ExecutionOptionItem] {
        allCases.map { provider in
            let isEnabled: Bool
            switch provider {
            case .builtInAgent:
                isEnabled = true
            case .githubCopilotCLI:
                isEnabled = isSelectableExternalStatus(copilotAvailabilityStatus.kind)
            case .openCodeCLI:
                isEnabled = isSelectableExternalStatus(openCodeAvailabilityStatus.kind)
            case .claudeAdapterCLI:
                isEnabled = isSelectableExternalStatus(claudeAdapterAvailabilityStatus.kind)
            }

            return ExecutionOptionItem(
                id: provider.rawValue,
                title: provider.displayName,
                isEnabled: isEnabled
            )
        }
    }

    private static func isSelectableExternalStatus(_ kind: ACPCLIAvailabilityStatus.Kind) -> Bool {
        switch kind {
        case .available, .notAuthenticated:
            return true
        case .notInstalled, .failed, .unknown:
            return false
        }
    }
}