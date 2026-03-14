import SwiftData
import SwiftUI

enum SettingsWindowScene {
    static let id = "settings-window"
}

struct SettingsWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @State private var store: SettingsStore?

    var body: some View {
        NavigationSplitView {
            List(SettingsNavigationItem.allCases, selection: selectionBinding) { item in
                Label(item.title, systemImage: item.symbolName)
                    .accessibilityIdentifier("settings.nav.\(item.rawValue)")
                    .tag(item)
            }
            .navigationTitle("设置")
            .frame(minWidth: 180)
        } detail: {
            detailView
        }
        .frame(minWidth: 960, minHeight: 620)
        .onAppear {
            if store == nil {
                store = SettingsStore(
                    modelContext: modelContext,
                    persistenceCoordinator: persistenceCoordinator
                )
            }
        }
    }

    private var selectionBinding: Binding<SettingsNavigationItem?> {
        Binding(
            get: { store?.selectedItem ?? .defaultItem },
            set: { newValue in
                if let newValue {
                    store?.selectedItem = newValue
                }
            }
        )
    }

    @ViewBuilder
    private var detailView: some View {
        if let store {
            NavigationStack(path: detailPathBinding(for: store)) {
                rootDetailView(store: store)
                    .navigationDestination(for: SettingsDetailRoute.self) { route in
                        switch route {
                        case .memoryGovernance:
                            MemoryManagementPanel(settings: store.settings)
                        }
                    }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailPathBinding(for store: SettingsStore) -> Binding<[SettingsDetailRoute]> {
        Binding(
            get: { store.detailPath },
            set: { store.detailPath = $0 }
        )
    }

    @ViewBuilder
    private func rootDetailView(store: SettingsStore) -> some View {
        switch store.selectedItem {
        case .connection:
            SettingsConnectionView(store: store)
        case .tools:
            SettingsToolsView(store: store)
        case .intelligence:
            SettingsIntelligenceView(store: store)
        case .memory:
            SettingsMemoryView(store: store)
        case .general:
            SettingsGeneralView(store: store)
        }
    }
}