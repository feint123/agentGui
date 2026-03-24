import Foundation

@MainActor
struct RecentWorkspaceStore {
    struct Item: Codable, Equatable, Identifiable {
        let path: String
        let displayName: String
        let lastOpenedAt: Date

        var id: String {
            path
        }
    }

    static let shared = RecentWorkspaceStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxItems: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "appCommand.recentWorkspaces",
        maxItems: Int = 10
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxItems = maxItems
    }

    var items: [Item] {
        loadItems()
    }

    func record(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        var updatedItems = loadItems().filter { $0.path != standardizedURL.path }
        updatedItems.insert(
            Item(
                path: standardizedURL.path,
                displayName: standardizedURL.lastPathComponent,
                lastOpenedAt: Date()
            ),
            at: 0
        )
        saveItems(Array(updatedItems.prefix(maxItems)))
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private func loadItems() -> [Item] {
        guard let data = defaults.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        return items.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func saveItems(_ items: [Item]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}