import Foundation
import Testing
@testable import agentGui

struct ChatComposerACPWarmupPolicyTests {

    @Test func requiresSlashQueryAndExternalProviderAndMissingACPCommands() {
        #expect(
            ChatComposerACPWarmupPolicy.shouldWarmup(
                slashQuery: nil,
                resolvedExecutionProviderID: .openCodeCLI,
                hasRemoteACPCommands: false,
                isWarmupInFlight: false
            ) == false
        )

        #expect(
            ChatComposerACPWarmupPolicy.shouldWarmup(
                slashQuery: "",
                resolvedExecutionProviderID: .builtInAgent,
                hasRemoteACPCommands: false,
                isWarmupInFlight: false
            ) == false
        )

        #expect(
            ChatComposerACPWarmupPolicy.shouldWarmup(
                slashQuery: "",
                resolvedExecutionProviderID: .openCodeCLI,
                hasRemoteACPCommands: true,
                isWarmupInFlight: false
            ) == false
        )

        #expect(
            ChatComposerACPWarmupPolicy.shouldWarmup(
                slashQuery: "",
                resolvedExecutionProviderID: .openCodeCLI,
                hasRemoteACPCommands: false,
                isWarmupInFlight: true
            ) == false
        )

        #expect(
            ChatComposerACPWarmupPolicy.shouldWarmup(
                slashQuery: "",
                resolvedExecutionProviderID: .openCodeCLI,
                hasRemoteACPCommands: false,
                isWarmupInFlight: false
            ) == true
        )
    }
}