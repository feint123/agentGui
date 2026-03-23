import Foundation
import Testing
@testable import agentGui

struct ChatComposerAvailabilityRefreshPolicyTests {
    @Test func startupRefreshIncludesAllExternalExecutionProviders() {
        #expect(ChatComposerAvailabilityRefreshPolicy.startupRefreshProviderIDs == [
            .githubCopilotCLI,
            .openCodeCLI,
            .claudeAdapterCLI
        ])
        #expect(ChatComposerAvailabilityRefreshPolicy.startupRefreshProviderIDs.contains(.builtInAgent) == false)
    }
}