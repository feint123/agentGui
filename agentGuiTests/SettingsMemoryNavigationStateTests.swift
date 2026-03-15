import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsMemoryNavigationStateTests {
    @Test func detailRouteUsesExpectedRMSPanelCase() {
        #expect(SettingsDetailRoute.rmsPanel.id == "rmsPanel")
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

        store.showRMSPanel()
        #expect(store.selectedItem == .memory)
        #expect(store.detailPath == [.rmsPanel])

        store.selectedItem = .general
        #expect(store.detailPath.isEmpty)
    }
}