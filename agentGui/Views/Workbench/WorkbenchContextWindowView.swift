import SwiftUI

enum WorkbenchContextWindowScene {
    static let id = "workbench-context-window"
}

struct WorkbenchContextWindowView: View {
    @Environment(WorkbenchContextWindowState.self) private var contextWindowState
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Namespace private var tabSelectionNamespace

    var body: some View {
        VStack(spacing: 0) {
            header

            if let selectedTab = contextWindowState.selectedTab {
                content(for: selectedTab)
                    .id(selectedTab.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        )
                    )
            } else {
                emptyState
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(background)
        .onChange(of: contextWindowState.tabs.count) { _, newCount in
            if newCount == 0 {
                dismiss()
            }
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.03), value: contextWindowState.selectedTabID)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTabTitle)
                        .font(.title3.weight(.semibold))

                    Text(selectedTabSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                SessionWorkspaceBadgeView(presentation: workspacePresentation)

                Button("全部关闭") {
                    contextWindowState.closeAllTabs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!contextWindowState.hasTabs)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(contextWindowState.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func content(for tab: WorkbenchContextTab) -> some View {
        switch tab.selection {
        case .none:
            emptyState

        case .file(let fileURL):
            FileEditorView(fileURL: fileURL)

        case .gitDiff(let title, let diffText):
            GitDiffView(
                title: title,
                diffText: diffText,
                backButtonTitle: "关闭标签页",
                onBack: {
                    contextWindowState.closeTab(id: tab.id)
                }
            )

        case .changeProposal(let proposalID, _):
            ChangeProposalReviewView(
                proposalID: proposalID,
                selectedFilePath: selectedProposalFilePathBinding(for: tab.id),
                onClose: {
                    contextWindowState.closeTab(id: tab.id)
                }
            )
        }
    }

    private func tabButton(_ tab: WorkbenchContextTab) -> some View {
        let presentation = tabPresentation(for: tab.selection)
        let isSelected = contextWindowState.selectedTabID == tab.id

        return HStack(spacing: 8) {
            Button {
                contextWindowState.selectTab(id: tab.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: presentation.systemImage)
                        .font(.caption.weight(.semibold))
                    Text(presentation.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(tabBackground(isSelected: isSelected))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                contextWindowState.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭标签页")
        }
        .padding(.horizontal, 2)
        .accessibilityIdentifier("contextWindow.tab.\(tab.id.uuidString)")
    }

    @ViewBuilder
    private func tabBackground(isSelected: Bool) -> some View {
        if isSelected {
            Capsule()
                .fill(Color.accentColor.opacity(0.18))
                .matchedGeometryEffect(id: "context-window-tab", in: tabSelectionNamespace)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.05))
        }
    }

    private func selectedProposalFilePathBinding(for tabID: UUID) -> Binding<String?> {
        Binding(
            get: {
                guard let tab = contextWindowState.tabs.first(where: { $0.id == tabID }),
                      case .changeProposal(_, let filePath) = tab.selection else {
                    return nil
                }

                return filePath
            },
            set: { newValue in
                contextWindowState.updateChangeProposalFilePath(forTabID: tabID, filePath: newValue)

                if workspaceState.selectedChangeProposalID != nil,
                   contextWindowState.selectedTabID == tabID {
                    workspaceState.selectedChangeProposalFilePath = newValue
                }
            }
        )
    }

    private var workspacePresentation: SessionWorkspacePresentation {
        SessionWorkspacePresentationFactory().build(
            session: workspaceState.selectedSession,
            globalWorkingDirectory: AppSettings.getOrCreate(in: modelContext).workingDirectory
        )
    }

    private var selectedTabTitle: String {
        guard let selectedTab else { return "上下文" }
        return tabPresentation(for: selectedTab.selection).title
    }

    private var selectedTabSubtitle: String {
        guard let selectedTab else { return "在这里查看文件、Diff 和变更提案。" }
        return tabPresentation(for: selectedTab.selection).subtitle
    }

    private var selectedTab: WorkbenchContextTab? {
        contextWindowState.selectedTab
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(NSColor.windowBackgroundColor),
                Color.accentColor.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有打开的上下文", systemImage: "rectangle.stack")
        } description: {
            Text("从工作区、Git 或提案入口打开内容后，这里会以标签页方式展示。")
        }
    }

    private func tabPresentation(for selection: WorkbenchDetailSelection) -> (
        title: String,
        subtitle: String,
        systemImage: String
    ) {
        switch selection {
        case .none:
            return (
                title: "上下文",
                subtitle: "在这里查看文件、Diff 和变更提案。",
                systemImage: "rectangle.stack"
            )

        case .file(let fileURL):
            return (
                title: fileURL.lastPathComponent,
                subtitle: fileURL.path,
                systemImage: "doc.text"
            )

        case .gitDiff(let title, _):
            return (
                title: URL(fileURLWithPath: title).lastPathComponent,
                subtitle: title,
                systemImage: "arrow.left.arrow.right.square"
            )

        case .changeProposal(let proposalID, let filePath):
            let snapshot = changeReviewProjectionStore.snapshot(for: proposalID)
            let resolvedTitle = filePath ?? snapshot?.proposal.summary ?? "变更提案"
            let resolvedSubtitle = snapshot?.proposal.summary ?? proposalID.uuidString

            return (
                title: URL(fileURLWithPath: resolvedTitle).lastPathComponent,
                subtitle: resolvedSubtitle,
                systemImage: "sparkles.rectangle.stack"
            )
        }
    }
}