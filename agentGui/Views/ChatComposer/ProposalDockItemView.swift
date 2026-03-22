import SwiftUI

struct ProposalDockItemView: View {
    let item: ProposalDockItemPresentation
    let isSelected: Bool
    let onOpen: () -> Void
    let onApply: () -> Void
    let onDiscard: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text("+\(item.changeSummary.additions)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)

                Text("-\(item.changeSummary.deletions)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)

                if isHovering {
                    dockIconButton(systemName: "checkmark", title: "接受提案", action: onApply)
                    dockIconButton(systemName: "xmark", title: "丢弃提案", action: onDiscard)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor)
        )
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("chat.proposalDock.item.\(item.id.uuidString)")
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }

        if isHovering {
            return Color.accentColor.opacity(0.08)
        }

        return .clear
    }

    private func dockIconButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}