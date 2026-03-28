import Foundation

#if canImport(Sparkle) && os(macOS)
import Sparkle
#endif

@MainActor
protocol SparkleUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func startUpdaterIfNeeded()
    func checkForUpdates()
    func resetUpdateCycleAfterShortDelay()
}

@MainActor
final class SparkleUpdateCoordinator {
    let driver: SparkleUpdating
    var updateChannel: SparkleUpdateChannel

    init(
        driver: SparkleUpdating,
        updateChannel: SparkleUpdateChannel = .stable
    ) {
        self.driver = driver
        self.updateChannel = updateChannel
    }

    var canCheckForUpdates: Bool {
        driver.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { driver.automaticallyChecksForUpdates }
        set { driver.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { driver.automaticallyDownloadsUpdates }
        set { driver.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        driver.checkForUpdates()
    }

    func startUpdaterIfNeeded() {
        driver.startUpdaterIfNeeded()
    }

    func resetUpdateCycleAfterShortDelay() {
        driver.resetUpdateCycleAfterShortDelay()
    }
}

#if canImport(Sparkle) && os(macOS)
@MainActor
final class LiveSparkleDriver: NSObject, SparkleUpdating {
    private let updaterDelegate: SparkleUpdateDelegate
    private let updaterController: SPUStandardUpdaterController
    private var hasStartedUpdater = false

    init(updaterDelegate: SparkleUpdateDelegate) {
        self.updaterDelegate = updaterDelegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        super.init()
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set { updaterController.updater.automaticallyDownloadsUpdates = newValue }
    }

    func startUpdaterIfNeeded() {
        guard !hasStartedUpdater else {
            return
        }
        hasStartedUpdater = true
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func resetUpdateCycleAfterShortDelay() {
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }
}
#endif

extension SparkleUpdateCoordinator: UpdateCommandHandling {}