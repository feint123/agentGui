import SwiftUI

struct GitPanelView: View {
    let showsBackground: Bool

    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(WorkspaceState.self) private var workspaceState
    @State private var sidebarViewModel: GitSidebarViewModel?

    init(showsBackground: Bool = true) {
        self.showsBackground = showsBackground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 10)
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
        HStack(spacing: 8) {
            Label("Git", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("git.panel.header")
            Spacer(minLength: 0)
            Button {
                guard let workingDirectory = gitPanelViewModel.currentWorkingDirectory else { return }
                Task { await gitPanelViewModel.refresh(for: workingDirectory, workspaceState: workspaceState) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(gitPanelViewModel.currentWorkingDirectory == nil || gitPanelViewModel.isLoading)
            .accessibilityIdentifier("git.panel.refresh")
        }
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
}