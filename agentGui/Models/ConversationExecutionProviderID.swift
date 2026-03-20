import Foundation

enum ConversationExecutionProviderID: String, Codable, CaseIterable, Sendable {
    case builtInAgent = "built_in_agent"
    case githubCopilotCLI = "github_copilot_cli"

    var displayName: String {
        switch self {
        case .builtInAgent:
            return "内置 Agent"
        case .githubCopilotCLI:
            return "GitHub Copilot CLI"
        }
    }
}