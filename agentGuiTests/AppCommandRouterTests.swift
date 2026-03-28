import Foundation
import Testing
@testable import agentGui

@MainActor
struct AppCommandRouterTests {
    @Test
    func checkForUpdatesCommandIsRegistered() {
        let descriptor = AppCommandRegistry().descriptor(for: .checkForUpdates)

        #expect(descriptor?.title == "检查更新...")
    }

    @Test
    func checkForUpdatesCommandInvokesCoordinator() async {
        let coordinator = StubUpdateCommandHandler(canCheckForUpdates: true)
        let router = AppCommandRouter()
        var context = AppCommandContext.preview()
        context.updateCommandHandler = coordinator

        let result = await router.perform(.checkForUpdates, in: context)

        #expect(result == .performed)
        #expect(coordinator.checkCallCount == 1)
    }

    @Test
    func checkForUpdatesCommandIsDisabledWithoutHandler() async {
        let router = AppCommandRouter()
        let context = AppCommandContext.preview()

        let result = await router.perform(.checkForUpdates, in: context)

        #expect(result == .disabled("当前无法检查更新。"))
    }

    @Test
    func checkForUpdatesCommandIsDisabledWhenHandlerCannotCheck() async {
        let coordinator = StubUpdateCommandHandler(canCheckForUpdates: false)
        let router = AppCommandRouter()
        var context = AppCommandContext.preview()
        context.updateCommandHandler = coordinator

        let result = await router.perform(.checkForUpdates, in: context)

        #expect(result == .disabled("当前无法检查更新。"))
        #expect(coordinator.checkCallCount == 0)
    }
}

@MainActor
private final class StubUpdateCommandHandler: UpdateCommandHandling {
    let canCheckForUpdates: Bool
    private(set) var checkCallCount = 0

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func checkForUpdates() {
        checkCallCount += 1
    }
}