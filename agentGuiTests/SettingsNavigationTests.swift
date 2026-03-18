import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SettingsNavigationTests {
    @Test func settingsNavigationUsesExpectedDefaultOrder() {
        #expect(SettingsNavigationItem.allCases == [.connection, .channels, .tools, .intelligence, .background, .memory, .general])
        #expect(SettingsNavigationItem.defaultItem == .connection)
        #expect(SettingsNavigationItem.connection.title == "连接")
        #expect(SettingsNavigationItem.connection.symbolName == "network")
        #expect(SettingsNavigationItem.channels.title == "渠道")
        #expect(SettingsNavigationItem.background.title == "后台任务")
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