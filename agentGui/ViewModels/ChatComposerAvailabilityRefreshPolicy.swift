import Foundation

enum ChatComposerAvailabilityRefreshPolicy {
    static let startupRefreshProviderIDs: [ConversationExecutionProviderID] = [
        .githubCopilotCLI,
        .openCodeCLI,
        .claudeAdapterCLI
    ]
}