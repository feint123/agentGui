import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsMemoryNavigationStateTests {
    @Test func detailRouteUsesExpectedMemoryGovernanceCase() {
        #expect(SettingsDetailRoute.memoryGovernance.id == "memoryGovernance")
    }

    @Test func switchingAwayFromMemoryClearsDetailPath() throws {
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

        store.showMemoryGovernance()
        #expect(store.selectedItem == .memory)
        #expect(store.detailPath == [.memoryGovernance])

        store.selectedItem = .general
        #expect(store.detailPath.isEmpty)
    }
}