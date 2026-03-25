import SwiftUI

struct ExecutionOptionPicker: View {
    let title: String
    let options: [ExecutionOptionItem]
    @Binding var selection: String
    let accessibilityIdentifier: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.id)
                    .disabled(!option.isEnabled)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#Preview {
    ExecutionOptionPicker(title: "Select Option", options: [ExecutionOptionItem(id: "1", title: "Option 1", isEnabled: true), ExecutionOptionItem(id: "2", title: "Option 2", isEnabled: true)], selection: .constant("1"), accessibilityIdentifier: "executionOptionPicker")
}
