import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct SettingsUpdatePreferencesTests {
    @Test
    func appSettingsPersistsSparkleUpdateChannel() throws {
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [ModelConfiguration(schema: Schema(PersistenceSchema.sharedModelTypes), isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: nil)

        settings.sparkleUpdateChannel = .beta
        try context.save()

        #expect(settings.sparkleUpdateChannelRaw == SparkleUpdateChannel.beta.rawValue)
        #expect(settings.sparkleUpdateChannel == .beta)
    }

    @Test
    func settingsStoreSyncsPersistedChannelIntoBridge() throws {
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [ModelConfiguration(schema: Schema(PersistenceSchema.sharedModelTypes), isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: nil)
        settings.sparkleUpdateChannel = .beta

        let driver = StubSparklePreferencesDriver(canCheckForUpdates: true)
        let bridge = SparkleUpdatePreferencesBridge(
            coordinator: SparkleUpdateCoordinator(driver: driver)
        )
        let store = SettingsStore(
            modelContext: context,
            persistenceCoordinator: nil,
            updatePreferencesBridge: bridge
        )

        #expect(store.settings.sparkleUpdateChannel == SparkleUpdateChannel.beta)
        #expect(bridge.updateChannel == SparkleUpdateChannel.beta)
    }

    @Test
    func automaticChecksMutationDoesNotWriteSparkleManagedFlagsIntoAppSettings() throws {
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [ModelConfiguration(schema: Schema(PersistenceSchema.sharedModelTypes), isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: nil)
        let originalChannelRaw = settings.sparkleUpdateChannelRaw

        let driver = StubSparklePreferencesDriver(canCheckForUpdates: true)
        let bridge = SparkleUpdatePreferencesBridge(
            coordinator: SparkleUpdateCoordinator(driver: driver)
        )
        let store = SettingsStore(
            modelContext: context,
            persistenceCoordinator: nil,
            updatePreferencesBridge: bridge
        )

        store.automaticUpdateChecksBinding().wrappedValue = true

        #expect(driver.automaticallyChecksForUpdates == true)
        #expect(store.settings.sparkleUpdateChannelRaw == originalChannelRaw)
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