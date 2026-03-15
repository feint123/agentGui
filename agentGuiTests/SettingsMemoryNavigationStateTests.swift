import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsMemoryNavigationStateTests {
    @Test func selectingMemoryUpdatesCurrentSettingsNavigationItem() throws {
        SettingsStore.resetSelectionMemoryForTesting()

        let container = try ModelContainer(
            for: Schema([AppSettings.self]),
            configurations: [ModelConfiguration(schema: Schema([AppSettings.self]), isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let store = SettingsStore(
            modelContext: context,
            persistenceCoordinator: nil
        )

        store.selectedItem = .memory
        #expect(store.selectedItem == .memory)

        store.selectedItem = .general

        #expect(store.selectedItem == .general)
    }
}