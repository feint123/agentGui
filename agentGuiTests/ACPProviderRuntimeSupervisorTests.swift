import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPProviderRuntimeSupervisorTests {
    @Test func supervisorReusesActivationWithinProvider() async {
        let registry = ACPSessionRuntimeRegistry()
        let supervisor = ACPProviderRuntimeSupervisor(providerID: .githubCopilotCLI, registry: registry)

        let first = await supervisor.activation(for: "session-1")
        let second = await supervisor.activation(for: "session-1")

        #expect(first === second)
    }

    @Test func supervisorShutdownOnlyRemovesOwnProviderActivations() async {
        let registry = ACPSessionRuntimeRegistry()
        let copilotSupervisor = ACPProviderRuntimeSupervisor(providerID: .githubCopilotCLI, registry: registry)
        let openCodeSupervisor = ACPProviderRuntimeSupervisor(providerID: .openCodeCLI, registry: registry)

        _ = await copilotSupervisor.activation(for: "session-a")
        _ = await openCodeSupervisor.activation(for: "session-a")

        await copilotSupervisor.shutdownProviderSessions()

        #expect(await registry.count(providerID: .githubCopilotCLI) == 0)
        #expect(await registry.count(providerID: .openCodeCLI) == 1)
    }
}