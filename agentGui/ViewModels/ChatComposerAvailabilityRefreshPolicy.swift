import Foundation

enum ChatComposerAvailabilityRefreshPolicy {
    static let startupRefreshProviderReferences: [ExecutionProviderReference] = [
        LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference,
        LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference,
        LegacyExternalACPProviderKey.claudeAdapterCLI.compatibilityReference
    ]
}