import Testing
@testable import agentGui

@MainActor
struct ChatExecutionProviderAvailabilityModelTests {
    @Test func doesNotProbeUntilRefreshIsRequested() async {
        var probeInvocationCount = 0
        let model = ChatExecutionProviderAvailabilityModel(
            probe: { _ in
                probeInvocationCount += 1
                return GitHubCopilotCLIAvailabilityStatus(kind: .available, version: nil)
            }
        )

        #expect(model.copilotStatus == .unknown)
        #expect(model.copilotStatus == .unknown)
        #expect(probeInvocationCount == 0)

        await model.refreshCopilotStatus(configuration: .default)

        #expect(model.copilotStatus.kind == .available)
        #expect(probeInvocationCount == 1)

        _ = model.copilotStatus
        #expect(probeInvocationCount == 1)
    }
}