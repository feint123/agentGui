import Foundation
import Testing
@testable import agentGui

@MainActor
struct SparkleUpdateCoordinatorTests {
    @Test
    func manualCheckDelegatesToDriver() async {
        let driver = StubSparkleDriver(canCheckForUpdates: true)
        let coordinator = SparkleUpdateCoordinator(driver: driver)

        await coordinator.checkForUpdates()

        #expect(driver.checkForUpdatesCallCount == 1)
    }

    @Test
    func canCheckForUpdatesMirrorsDriverState() {
        let driver = StubSparkleDriver(canCheckForUpdates: false)
        let coordinator = SparkleUpdateCoordinator(driver: driver)

        #expect(coordinator.canCheckForUpdates == false)
    }

    @Test
    func delegateReturnsAllowedChannelsForBetaSelection() {
        let betaDelegate = SparkleUpdateDelegate { .beta }
        let stableDelegate = SparkleUpdateDelegate { .stable }

        #expect(betaDelegate.allowedChannels() == Set(["beta"]))
        #expect(stableDelegate.allowedChannels().isEmpty)
    }
}

@MainActor
private final class StubSparkleDriver: SparkleUpdating {
    let canCheckForUpdates: Bool
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    private(set) var checkForUpdatesCallCount = 0
    private(set) var resetUpdateCycleCallCount = 0

    init(canCheckForUpdates: Bool) {
        self.canCheckForUpdates = canCheckForUpdates
    }

    func startUpdaterIfNeeded() {}

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func resetUpdateCycleAfterShortDelay() {
        resetUpdateCycleCallCount += 1
    }
}