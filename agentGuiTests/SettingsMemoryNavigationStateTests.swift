import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsMemoryNavigationStateTests {
    @Test func detailRouteUsesExpectedRMSCognitionCase() {
        #expect(SettingsDetailRoute.rmsCognition.id == "rmsCognition")
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

        store.showRMSCognitionPanel()
        #expect(store.selectedItem == .memory)
        #expect(store.detailPath == [.rmsCognition])

        store.selectedItem = .general
        #expect(store.detailPath.isEmpty)
    }
}