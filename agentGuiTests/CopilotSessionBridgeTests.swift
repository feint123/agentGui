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
            lastHandshakeAt: Date(timeIntervalSince1970: 1),
            lastSelectedModel: "gpt-5",
            lastSelectedAgentName: "coder"
        )

        await bridge.upsert(binding)

        let resolved = await bridge.binding(for: "local-1")
        #expect(resolved == binding)
    }
}