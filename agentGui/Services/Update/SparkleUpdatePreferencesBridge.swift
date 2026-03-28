import Foundation

@MainActor
final class SparkleUpdatePreferencesBridge {
    private let coordinator: SparkleUpdateCoordinator

    init(coordinator: SparkleUpdateCoordinator) {
        self.coordinator = coordinator
    }

    var automaticallyChecksForUpdates: Bool {
        get { coordinator.automaticallyChecksForUpdates }
        set { coordinator.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { coordinator.automaticallyDownloadsUpdates }
        set { coordinator.automaticallyDownloadsUpdates = newValue }
    }

    var updateChannel: SparkleUpdateChannel {
        get { coordinator.updateChannel }
        set {
            guard coordinator.updateChannel != newValue else {
                return
            }
            coordinator.updateChannel = newValue
            coordinator.resetUpdateCycleAfterShortDelay()
        }
    }
}