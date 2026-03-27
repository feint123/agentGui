import SwiftUI
import SwiftData

struct NewSessionExecutionProviderMenu<Label: View>: View {
    @Environment(\.modelContext) private var modelContext

    let options: [ExecutionOptionItem]
    let accessibilityIdentifier: String?
    let onSelect: (ExecutionProviderReference) -> Void
    let label: () -> Label

    init(
        options: [ExecutionOptionItem]? = nil,
        accessibilityIdentifier: String? = nil,
        onSelect: @escaping (ExecutionProviderReference) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.options = options ?? []
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(resolvedOptions) { option in
                Button(option.title) {
                    onSelect(ExecutionProviderReference.decodePersisted(option.id))
                }
                .disabled(option.isEnabled == false)
            }
        } label: {
            label()
        }
        .applyAccessibilityIdentifier(accessibilityIdentifier)
    }

    private var resolvedOptions: [ExecutionOptionItem] {
        if options.isEmpty == false {
            return options
        }

        let store = SettingsStore(modelContext: modelContext, persistenceCoordinator: nil)
        return store.defaultExecutionProviderOptions()
    }
}