import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPSessionRuntimeRegistryTests {
    @Test func registryReturnsSameActivationForSameKey() async {
        let registry = ACPSessionRuntimeRegistry()
        let key = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-1")

        let first = await registry.activation(for: key)
        let second = await registry.activation(for: key)

        #expect(first === second)
    }

    @Test func registrySeparatesSessionsByProviderAndLocalSession() async {
        let registry = ACPSessionRuntimeRegistry()

        let copilot = await registry.activation(for: .init(providerID: .githubCopilotCLI, localSessionID: "s1"))
        let openCode = await registry.activation(for: .init(providerID: .openCodeCLI, localSessionID: "s1"))

        #expect(copilot !== openCode)
        #expect(await registry.count() == 2)
    }

    @Test func registryRebuildReplacesOnlyCurrentKey() async {
        let registry = ACPSessionRuntimeRegistry()
        let firstKey = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "s1")
        let secondKey = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "s2")

        let first = await registry.activation(for: firstKey)
        let second = await registry.activation(for: secondKey)
        let rebuilt = await registry.rebuildActivation(for: firstKey)
        let secondAfterRebuild = await registry.activation(for: secondKey)

        #expect(first !== rebuilt)
        #expect(second === secondAfterRebuild)
    }
}