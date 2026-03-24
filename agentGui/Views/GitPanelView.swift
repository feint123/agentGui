import SwiftUI

struct GitPanelView: View {
    let showsBackground: Bool
    let showsHeader: Bool

    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(WorkspaceState.self) private var workspaceState
    @State private var sidebarViewModel: GitSidebarViewModel?

    init(showsBackground: Bool = true, showsHeader: Bool = true) {
        self.showsBackground = showsBackground
        self.showsHeader = showsHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSidebarPanelStyle.sectionSpacing) {
            if showsHeader {
                header
            }

            if let sidebarViewModel, let snapshot = gitPanelViewModel.snapshot {
                GitSidebarOverviewSection(snapshot: snapshot, operationState: gitPanelViewModel.operationState)
                GitSidebarChangesSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
                GitSidebarCommitSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
                GitSidebarBranchSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
                GitSidebarUtilitiesSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
            } else if gitPanelViewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                emptyState
            }
        }
        .background {
            if showsBackground {
                RoundedRectangle(
                    cornerRadius: WorkbenchSidebarPanelStyle.cardCornerRadius,
                    style: .continuous
                )
                .fill(Color.primary.opacity(0.03))
            }
        }
        .accessibilityIdentifier("git.panel")
        .task {
            if sidebarViewModel == nil {
                sidebarViewModel = GitSidebarViewModel(panelViewModel: gitPanelViewModel)
            }
        }
        .alert(
            "Git 操作失败",
            isPresented: Binding(
                get: { activeErrorMessage != nil && gitPanelViewModel.snapshot != nil },
                set: {
                    if !$0 {
                        gitPanelViewModel.loadError = nil
                        gitPanelViewModel.branchActionError = nil
                    }
                }
            )
        ) {
            Button("确定") {
                gitPanelViewModel.loadError = nil
                gitPanelViewModel.branchActionError = nil
            }
        } message: {
            Text(activeErrorMessage ?? "")
        }
    }

    private var header: some View {
        GitPanelHeaderBar(
            isLoading: gitPanelViewModel.isLoading,
            canRefresh: gitPanelViewModel.currentWorkingDirectory != nil,
            onRefresh: refresh
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前目录不是 Git 仓库")
                .font(.caption.weight(.medium))
            Text("切换到仓库目录后，这里会显示仓库摘要和分支入口。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var activeErrorMessage: String? {
        gitPanelViewModel.branchActionError ?? gitPanelViewModel.loadError
    }

    private func refresh() {
        guard let workingDirectory = gitPanelViewModel.currentWorkingDirectory else { return }
        Task {
            await gitPanelViewModel.refresh(for: workingDirectory, workspaceState: workspaceState)
        }
    }
}

struct GitPanelHeaderBar: View {
    let isLoading: Bool
    let canRefresh: Bool
    let onRefresh: () -> Void

    var body: some View {
        WorkbenchSidebarToolbarHeader {
            Label("Git", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("git.panel.header")
        } trailing: {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!canRefresh || isLoading)
            .accessibilityIdentifier("git.panel.refresh")
        }
    }
}