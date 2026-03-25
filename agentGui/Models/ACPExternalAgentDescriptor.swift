import Foundation

struct ACPExternalAgentDescriptor: Equatable, Sendable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let defaultExecutablePath: String
    let defaultArguments: [String]
    let defaultEnvironment: [String: String]
}

extension ACPExternalAgentDescriptor {
    static let githubCopilot = ACPExternalAgentDescriptor(
        providerID: .githubCopilotCLI,
        displayName: "GitHub Copilot",
        defaultExecutablePath: ACPCLIConfiguration.githubCopilotDefault.executablePath,
        defaultArguments: ["--acp", "--stdio"],
        defaultEnvironment: [:]
    )

    static let openCode = ACPExternalAgentDescriptor(
        providerID: .openCodeCLI,
        displayName: "OpenCode",
        defaultExecutablePath: ACPCLIConfiguration.openCodeDefault.executablePath,
        defaultArguments: ["acp"],
        defaultEnvironment: [:]
    )

    static let claudeAdapter = ACPExternalAgentDescriptor(
        providerID: .claudeAdapterCLI,
        displayName: "Claude Code",
        defaultExecutablePath: ACPCLIConfiguration.claudeAdapterDefault.executablePath,
        defaultArguments: [],
        defaultEnvironment: [:]
    )
}