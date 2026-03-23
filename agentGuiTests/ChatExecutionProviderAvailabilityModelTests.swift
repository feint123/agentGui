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

    @Test func marksProviderAsRefreshingWhileProbeIsInFlight() async {
        let gate = AsyncProbeGate()
        let model = ChatExecutionProviderAvailabilityModel(
            probe: { providerID, _ in
                await gate.wait()
                return ACPCLIAvailabilityStatus(kind: .available, version: providerID.rawValue)
            }
        )

        let refreshTask = Task {
            await model.refreshStatus(for: .githubCopilotCLI, executablePath: "copilot")
        }

        await Task.yield()

        #expect(model.isRefreshingCopilotStatus)
        #expect(model.isRefreshingOpenCodeStatus == false)

        gate.release()
        await refreshTask.value

        #expect(model.isRefreshingCopilotStatus == false)
        #expect(model.copilotStatus.kind == .available)
        #expect(model.copilotStatus.version == ConversationExecutionProviderID.githubCopilotCLI.rawValue)
    }
}

private actor AsyncProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}