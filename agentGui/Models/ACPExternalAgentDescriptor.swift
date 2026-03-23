import Foundation

struct ACPExternalAgentDescriptor: Equatable, Sendable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let defaultExecutablePath: String
    let defaultArguments: [String]
    let supportsSessionModelOverrideByDefault: Bool
    let supportsCustomAgentName: Bool
    let defaultEnvironment: [String: String]
    let executionBehavior: ACPExternalProviderExecutionBehavior
}

extension ACPExternalAgentDescriptor {
    static let githubCopilot = ACPExternalAgentDescriptor(
        providerID: .githubCopilotCLI,
        displayName: "GitHub Copilot",
        defaultExecutablePath: ACPCLIConfiguration.githubCopilotDefault.executablePath,
        defaultArguments: ["--acp", "--stdio"],
        supportsSessionModelOverrideByDefault: true,
        supportsCustomAgentName: false,
        defaultEnvironment: [:],
        executionBehavior: ACPExternalProviderExecutionBehavior(
            requiresCapabilityNegotiationForModelOverride: false,
            supportsEnvironmentOverrides: false,
            supportsCustomAgentName: false
        )
    )

    static let openCode = ACPExternalAgentDescriptor(
        providerID: .openCodeCLI,
        displayName: "OpenCode",
        defaultExecutablePath: ACPCLIConfiguration.openCodeDefault.executablePath,
        defaultArguments: ["acp"],
        supportsSessionModelOverrideByDefault: false,
        supportsCustomAgentName: false,
        defaultEnvironment: [:],
        executionBehavior: ACPExternalProviderExecutionBehavior(
            requiresCapabilityNegotiationForModelOverride: true,
            supportsEnvironmentOverrides: false,
            supportsCustomAgentName: false
        )
    )

    static let claudeAdapter = ACPExternalAgentDescriptor(
        providerID: .claudeAdapterCLI,
        displayName: "Claude Code",
        defaultExecutablePath: ACPCLIConfiguration.claudeAdapterDefault.executablePath,
        defaultArguments: [],
        supportsSessionModelOverrideByDefault: false,
        supportsCustomAgentName: false,
        defaultEnvironment: [:],
        executionBehavior: ACPExternalProviderExecutionBehavior(
            requiresCapabilityNegotiationForModelOverride: true,
            supportsEnvironmentOverrides: false,
            supportsCustomAgentName: false
        )
    )
}