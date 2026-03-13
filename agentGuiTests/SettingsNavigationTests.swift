import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsNavigationTests {
    @Test func settingsNavigationUsesExpectedDefaultOrder() {
        #expect(SettingsNavigationItem.allCases == [.connection, .tools, .intelligence, .memory, .general])
        #expect(SettingsNavigationItem.defaultItem == .connection)
        #expect(SettingsNavigationItem.connection.title == "连接")
        #expect(SettingsNavigationItem.connection.symbolName == "network")
    }

    @Test func settingsStoreUsesConnectionAsDefaultSelection() throws {
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

        #expect(store.selectedItem == .connection)
        #expect(store.settings.selectedModel == "claude-sonnet-4-6")

        store.selectedItem = .memory

        #expect(store.selectedItem == .memory)
    }
}