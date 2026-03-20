import Foundation

struct ACPExternalAgentDescriptor: Equatable, Sendable {
    let providerID: ConversationExecutionProviderID
    let displayName: String
    let defaultExecutablePath: String
    let defaultArguments: [String]
    let supportsSessionModelOverrideByDefault: Bool
    let supportsCustomAgentName: Bool
    let defaultEnvironment: [String: String]
}

extension ACPExternalAgentDescriptor {
    static let openCode = ACPExternalAgentDescriptor(
        providerID: .openCodeCLI,
        displayName: "OpenCode",
        defaultExecutablePath: OpenCodeCLIConfiguration.default.executablePath,
        defaultArguments: ["acp"],
        supportsSessionModelOverrideByDefault: false,
        supportsCustomAgentName: false,
        defaultEnvironment: [:]
    )
}