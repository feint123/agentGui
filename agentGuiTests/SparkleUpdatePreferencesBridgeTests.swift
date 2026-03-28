import Foundation
import Testing
@testable import agentGui

@MainActor
struct SparkleUpdatePreferencesBridgeTests {
    @Test
    func automaticChecksBindingReadsAndWritesDriverState() {
        let driver = StubSparklePreferencesDriver(canCheckForUpdates: true)
        let bridge = SparkleUpdatePreferencesBridge(
            coordinator: SparkleUpdateCoordinator(driver: driver)
        )

        #expect(bridge.automaticallyChecksForUpdates == false)

        bridge.automaticallyChecksForUpdates = true

        #expect(driver.automaticallyChecksForUpdates == true)
    }

    @Test
    func automaticDownloadsBindingReadsAndWritesDriverState() {
        let driver = StubSparklePreferencesDriver(canCheckForUpdates: true)
        let bridge = SparkleUpdatePreferencesBridge(
            coordinator: SparkleUpdateCoordinator(driver: driver)
        )

        #expect(bridge.automaticallyDownloadsUpdates == false)

        bridge.automaticallyDownloadsUpdates = true

        #expect(driver.automaticallyDownloadsUpdates == true)
    }

    @Test
    func changingUpdateChannelResetsUpdateCycle() {
        let driver = StubSparklePreferencesDriver(canCheckForUpdates: true)
        let bridge = SparkleUpdatePreferencesBridge(
            coordinator: SparkleUpdateCoordinator(driver: driver)
        )

        bridge.updateChannel = .beta

        #expect(driver.resetUpdateCycleCallCount == 1)
        #expect(bridge.updateChannel == .beta)
    }
}

@MainActor
private final class StubSparklePreferencesDriver: SparkleUpdating {
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