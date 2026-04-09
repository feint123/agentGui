import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorLSPCoordinatorCancellationTests {
    @Test
    func newHoverRequestCancelsOlderInFlightLSPRequest() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        // Schedule first hover (will send LSP request after debounce)
        var deliveries: [CodeEditorHoverPresentation?] = []
        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) { deliveries.append($0) }

        // Wait for debounce to pass — request is now in-flight (server will delay 200ms)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Schedule second hover — should cancel the first in-flight request
        coordinator.scheduleHover(
            at: .init(line: 1, column: 5, utf16Offset: 4, version: 1),
            debounceNanoseconds: 5_000_000
        ) { deliveries.append($0) }

        try await Task.sleep(nanoseconds: 350_000_000)

        // The harness should have captured at least one $/cancelRequest notification
        #expect(harness.cancelRequestIDs.count >= 1,
                "Expected at least one $/cancelRequest notification sent to server")
    }

    @Test
    func cancelHoverSendsCancelRequestToServer() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) { _ in }

        // Wait for debounce to pass (request is now in-flight)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Explicit cancel
        coordinator.cancelHover()

        // Give async tasks time to process
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(harness.cancelRequestIDs.count >= 1,
                "cancelHover() should send $/cancelRequest")
    }

    @Test
    func existingNonCancellableMethodsStillWork() async throws {
        // Verify backward compatibility: the original non-cancellable
        // requestDefinition path still works without regressions
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        let revealRequest = await coordinator.requestDefinition(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1)
        )

        #expect(revealRequest?.reason == .definition)
    }

    // MARK: - Task 5: Definition/References cancellation

    @Test
    func consecutiveDefinitionRequestsCancelPrevious() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        // Start first definition request
        let task1 = Task {
            await coordinator.requestDefinition(
                at: .init(line: 1, column: 1, utf16Offset: 0, version: 1)
            )
        }

        // Give time for request to be in-flight
        try await Task.sleep(nanoseconds: 10_000_000)

        // Fire second request — should cancel the first
        let task2 = Task {
            await coordinator.requestDefinition(
                at: .init(line: 1, column: 5, utf16Offset: 4, version: 1)
            )
        }

        _ = await task1.value
        _ = await task2.value

        // Give async tasks time to process cancel notifications
        try await Task.sleep(nanoseconds: 50_000_000)

        // At least one cancel request should have been sent
        #expect(harness.cancelRequestIDs.count >= 1,
                "Expected at least one $/cancelRequest for consecutive definition requests")
    }

    @Test
    func deactivateCancelsAllInFlightRequests() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        // Start hover (debounce 5ms, then in-flight for 200ms)
        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) { _ in }

        // Let debounce pass — request is now in-flight
        try await Task.sleep(nanoseconds: 30_000_000)

        // Deactivate should cancel everything
        coordinator.deactivate()

        // Give async tasks time to process cancel notifications
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(harness.cancelRequestIDs.count >= 1,
                "deactivate() should cancel in-flight LSP requests")
    }
}
