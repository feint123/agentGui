import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private static var lastSelectedItem: SettingsNavigationItem = .defaultItem

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let persistenceCoordinator: PersistenceCoordinator?

    var settings: AppSettings
    var selectedItem: SettingsNavigationItem {
        didSet {
            Self.lastSelectedItem = selectedItem
        }
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.settings = AppSettings.getOrCreate(
            in: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
        self.selectedItem = Self.lastSelectedItem
    }

    @discardableResult
    func persistSettingsMutation(_ userMessage: String, mutation: () -> Void) -> Bool {
        mutation()
        do {
            if let persistenceCoordinator {
                try persistenceCoordinator.save(modelContext, domain: .settings, userMessage: userMessage)
            } else {
                try modelContext.save()
            }
            return true
        } catch {
            return false
        }
    }

    func persistedSettingsBinding<Value>(
        get: @escaping () -> Value,
        userMessage: String,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                _ = self.persistSettingsMutation(userMessage) {
                    set(newValue)
                }
            }
        )
    }

    static func resetSelectionMemoryForTesting() {
        lastSelectedItem = .defaultItem
    }
}