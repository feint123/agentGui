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
        .pickerStyle(.menu)
        .controlSize(.small)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}