import SwiftUI

struct ACPSessionConfigurationControls: View {
    let presentation: ACPSessionConfigurationPresentation
    let onSelectMode: (String) -> Void
    let onSelectConfigOption: (String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !presentation.modeOptions.isEmpty {
                ACPConfigurationCapsuleMenu(
                    options: presentation.modeOptions,
                    selectedID: presentation.selectedModeID ?? presentation.modeOptions.first?.id ?? "",
                    onSelect: onSelectMode,
                    accessibilityIdentifier: "chat.acpModePicker"
                )
            }

            if let modelConfig = presentation.modelConfig {
                ACPConfigurationCapsuleMenu(
                    options: modelConfig.options,
                    selectedID: modelConfig.selectedValue,
                    onSelect: { onSelectConfigOption(modelConfig.id, $0) },
                    accessibilityIdentifier: "chat.acpModelPicker"
                )
            }

            if let approvalsConfig = presentation.approvalsConfig {
                ACPConfigurationCapsuleMenu(
                    options: approvalsConfig.options,
                    selectedID: approvalsConfig.selectedValue,
                    onSelect: { onSelectConfigOption(approvalsConfig.id, $0) },
                    accessibilityIdentifier: "chat.acpApprovalPicker"
                )
            }
        }
    }
}

private struct ACPConfigurationCapsuleMenu: View {
    let options: [ExecutionOptionItem]
    let selectedID: String
    let onSelect: (String) -> Void
    let accessibilityIdentifier: String

    @State private var isHovered = false

    private var selectedTitle: String {
        options.first(where: { $0.id == selectedID })?.title ?? selectedID
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.title) {
                    onSelect(option.id)
                }
                .disabled(!option.isEnabled)
            }
        } label: {
            Text(selectedTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .controlSize(.small)
        .contentShape(Capsule(style: .continuous))
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(isHovered ? 0.22 : 0.16))
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { isHovered = $0 }
    }
}

