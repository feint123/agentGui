import Foundation

struct GitHubCopilotCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var customAgentName: String
    var defaultApprovalMode: String
    var useACPStdIO: Bool

    static let `default` = GitHubCopilotCLIConfiguration(
        executablePath: "copilot",
        defaultModel: "",
        customAgentName: "",
        defaultApprovalMode: "default",
        useACPStdIO: true
    )
}