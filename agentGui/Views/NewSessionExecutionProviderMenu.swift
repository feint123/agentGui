import SwiftUI

struct NewSessionExecutionProviderMenu<Label: View>: View {
    let options: [ExecutionOptionItem]
    let accessibilityIdentifier: String?
    let onSelect: (ConversationExecutionProviderID) -> Void
    let label: () -> Label

    init(
        options: [ExecutionOptionItem] = ConversationExecutionProviderID.newSessionOptionItems(),
        accessibilityIdentifier: String? = nil,
        onSelect: @escaping (ConversationExecutionProviderID) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.options = options
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
        self.label = label
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.title) {
                    guard let providerID = ConversationExecutionProviderID(rawValue: option.id) else {
                        return
                    }
                    onSelect(providerID)
                }
                .disabled(option.isEnabled == false)
            }
        } label: {
            label()
        }
        .applyAccessibilityIdentifier(accessibilityIdentifier)
    }
}