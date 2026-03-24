import Foundation
import Testing
@testable import agentGui

@MainActor
struct RecentWorkspaceStoreTests {
    @Test func recordDeduplicatesByStandardizedPath() {
        let suiteName = "RecentWorkspaceStoreTests.\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = RecentWorkspaceStore(defaults: defaults, storageKey: "recent-workspaces")

        store.record(URL(fileURLWithPath: "/tmp/repo"))
        store.record(URL(fileURLWithPath: "/tmp/./repo"))

        #expect(store.items.count == 1)
        #expect(store.items.first?.path == "/tmp/repo")
        #expect(store.items.first?.displayName == "repo")

        defaults.removePersistentDomain(forName: suiteName)
    }
}