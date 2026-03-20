import Foundation
import Testing
@testable import agentGui

struct CopilotSessionBridgeTests {
    @Test func bridgeReusesRemoteSessionForSameLocalSession() async {
        let bridge = CopilotSessionBridge()
        let binding = CopilotSessionBridge.Binding(
            sessionID: "local-1",
            providerID: .githubCopilotCLI,
            remoteSessionID: "copilot-1",
            cliVersion: "1.0.0",
            negotiatedCapabilities: .init(loadSession: true, supportsSessionModelOverride: false, agentVersion: "1.0.0"),
            lastHandshakeAt: Date(timeIntervalSince1970: 1),
            lastSelectedModel: "gpt-5",
            lastSelectedAgentName: "coder"
        )

        await bridge.upsert(binding)

        let resolved = await bridge.binding(for: "local-1", providerID: .githubCopilotCLI)
        #expect(resolved == binding)
    }

    @Test func bridgeKeepsBindingsSeparatePerProvider() async {
        let bridge = CopilotSessionBridge()
        let copilotBinding = CopilotSessionBridge.Binding(
            sessionID: "local-1",
            providerID: .githubCopilotCLI,
            remoteSessionID: "copilot-1",
            cliVersion: "1.0.0",
            negotiatedCapabilities: .init(loadSession: true, supportsSessionModelOverride: true, agentVersion: "1.0.0"),
            lastHandshakeAt: Date(timeIntervalSince1970: 1),
            lastSelectedModel: "gpt-5",
            lastSelectedAgentName: "coder"
        )
        let openCodeBinding = CopilotSessionBridge.Binding(
            sessionID: "local-1",
            providerID: .openCodeCLI,
            remoteSessionID: "opencode-1",
            cliVersion: "0.4.0",
            negotiatedCapabilities: .init(loadSession: false, supportsSessionModelOverride: false, agentVersion: "0.4.0"),
            lastHandshakeAt: Date(timeIntervalSince1970: 2),
            lastSelectedModel: nil,
            lastSelectedAgentName: nil
        )

        await bridge.upsert(copilotBinding)
        await bridge.upsert(openCodeBinding)

        let resolvedCopilot = await bridge.binding(for: "local-1", providerID: .githubCopilotCLI)
        let resolvedOpenCode = await bridge.binding(for: "local-1", providerID: .openCodeCLI)

        #expect(resolvedCopilot == copilotBinding)
        #expect(resolvedOpenCode == openCodeBinding)
    }
}