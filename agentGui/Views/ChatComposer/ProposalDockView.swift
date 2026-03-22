import SwiftUI

struct ProposalDockView: View {
    let presentation: ProposalDockPresentation
    let selectedProposalID: UUID?
    let selectedFilePath: String?
    let onOpenProposal: (ProposalDockItemPresentation) -> Void
    let onApplyProposal: (ProposalDockItemPresentation) -> Void
    let onDiscardProposal: (ProposalDockItemPresentation) -> Void
    let onApplyAll: () -> Void
    let onDiscardAll: () -> Void

    @State private var isExpanded = true

    var body: some View {
        if presentation.isVisible {
            ComposerAssistPanelContainer(
                title: presentation.title,
                subtitle: presentation.summaryText,
                accessibilityIdentifier: "chat.proposalDock",
                accessory: {
                    Button(action: toggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "折叠变更队列" : "展开变更队列")
                    .accessibilityIdentifier("chat.proposalDock.toggle")
                }
            ) {
                VStack(spacing: 0) {
                    bulkActionsRow

                    if isExpanded {
                        if presentation.items.count > ChatSurfaceLayoutMetrics.proposalDockMaxVisibleRows {
                            ScrollView {
                                dockItemsList
                            }
                            .frame(maxHeight: ChatSurfaceLayoutMetrics.proposalDockMaxHeight)
                        } else {
                            dockItemsList
                        }
                    }
                }
            }
        }
    }

    private var bulkActionsRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("\(presentation.pendingFileCount) 个文件")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("+\(presentation.totalAdditions)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)

                Text("-\(presentation.totalDeletions)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            Button("全部同意", action: onApplyAll)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(presentation.actionableProposalIDs.isEmpty)
                .accessibilityIdentifier("chat.proposalDock.applyAll")

            Button("全部拒绝", role: .destructive, action: onDiscardAll)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(presentation.actionableProposalIDs.isEmpty)
                .accessibilityIdentifier("chat.proposalDock.discardAll")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var dockItemsList: some View {
        VStack(spacing: 0) {
            ForEach(presentation.items) { item in
                ProposalDockItemView(
                    item: item,
                    isSelected: isSelected(item),
                    onOpen: {
                        onOpenProposal(item)
                    },
                    onApply: {
                        onApplyProposal(item)
                    },
                    onDiscard: {
                        onDiscardProposal(item)
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func isSelected(_ item: ProposalDockItemPresentation) -> Bool {
        guard item.proposalID == selectedProposalID else {
            return false
        }

        if let selectedFilePath {
            return item.filePath == selectedFilePath
        }

        return presentation.items.first(where: { $0.proposalID == item.proposalID })?.id == item.id
    }

    private func toggleExpanded() {
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            isExpanded.toggle()
        }
    }
}