import Testing
@testable import agentGui

@MainActor
struct ChatExecutionProviderAvailabilityModelTests {
    @Test func doesNotProbeUntilRefreshIsRequested() async {
        var probes: [ConversationExecutionProviderID] = []
        let model = ChatExecutionProviderAvailabilityModel(
            probe: { providerID, _ in
                probes.append(providerID)
                return ACPCLIAvailabilityStatus(kind: .available, version: nil)
            }
        )

        #expect(model.copilotStatus == .unknown)
        #expect(model.openCodeStatus == .unknown)
        #expect(model.copilotStatus == .unknown)
        #expect(probes.isEmpty)

        await model.refreshStatus(for: .openCodeCLI, executablePath: "opencode")

        #expect(model.openCodeStatus.kind == .available)
        #expect(model.copilotStatus == .unknown)
        #expect(probes == [.openCodeCLI])

        _ = model.openCodeStatus
        #expect(probes == [.openCodeCLI])
    }
}