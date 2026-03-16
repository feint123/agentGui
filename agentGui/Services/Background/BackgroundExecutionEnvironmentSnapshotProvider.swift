import Foundation
import IOKit.ps
import Network

struct BackgroundExecutionEnvironmentSnapshot: Equatable, Sendable {
    var networkAvailable: Bool?
    var externalPowerConnected: Bool?

    init(
        networkAvailable: Bool? = nil,
        externalPowerConnected: Bool? = nil
    ) {
        self.networkAvailable = networkAvailable
        self.externalPowerConnected = externalPowerConnected
    }
}

protocol BackgroundExecutionEnvironmentSnapshotProviding {
    func currentSnapshot() -> BackgroundExecutionEnvironmentSnapshot
}

struct LiveBackgroundExecutionEnvironmentSnapshotProvider: BackgroundExecutionEnvironmentSnapshotProviding {
    private let networkAvailabilityReader: () -> Bool?
    private let externalPowerReader: () -> Bool?

    init(
        networkAvailabilityReader: @escaping () -> Bool? = Self.currentNetworkAvailability,
        externalPowerReader: @escaping () -> Bool? = Self.currentExternalPowerConnection
    ) {
        self.networkAvailabilityReader = networkAvailabilityReader
        self.externalPowerReader = externalPowerReader
    }

    func currentSnapshot() -> BackgroundExecutionEnvironmentSnapshot {
        BackgroundExecutionEnvironmentSnapshot(
            networkAvailable: networkAvailabilityReader(),
            externalPowerConnected: externalPowerReader()
        )
    }

    private static func currentNetworkAvailability() -> Bool? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.agentgui.background.network-snapshot")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolvedStatus: Bool?

        monitor.pathUpdateHandler = { path in
            lock.lock()
            if resolvedStatus == nil {
                resolvedStatus = path.status == .satisfied
                semaphore.signal()
            }
            lock.unlock()
        }

        monitor.start(queue: queue)
        defer { monitor.cancel() }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(1))
        guard waitResult == .success else {
            return nil
        }

        lock.lock()
        let snapshot = resolvedStatus
        lock.unlock()
        return snapshot
    }

    private static func currentExternalPowerConnection() -> Bool? {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else {
            return nil
        }

        return source == kIOPSACPowerValue as String
    }
}