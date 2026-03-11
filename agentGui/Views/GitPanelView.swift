import SwiftUI

struct GitPanelView: View {
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let snapshot = gitPanelViewModel.snapshot {
                summary(snapshot)
                branchSwitcher
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
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("git.panel")
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

    private func summary(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.repositoryName)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("git.summary.repository")
                    Text(snapshot.branchName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("git.summary.branch")
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                statPill("Staged", count: snapshot.stagedChanges.count)
                statPill("Modified", count: snapshot.unstagedChanges.count)
                statPill("Untracked", count: snapshot.untrackedChanges.count)
            }
            .accessibilityIdentifier("git.panel.summary")

            if snapshot.hasRemoteTrackingBranch {
                Text("Ahead \(snapshot.aheadCount) · Behind \(snapshot.behindCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.stagedChanges.isEmpty && snapshot.unstagedChanges.isEmpty && snapshot.untrackedChanges.isEmpty {
                Text("工作区干净")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var branchSwitcher: some View {
        HStack(spacing: 8) {
            Menu {
                if gitPanelViewModel.availableBranches.isEmpty {
                    Text("暂无可切换分支")
                } else {
                    ForEach(gitPanelViewModel.availableBranches) { branch in
                        Button(branch.name) {
                            Task { await gitPanelViewModel.switchBranch(to: branch.name) }
                        }
                        .disabled(branch.isCurrent || gitPanelViewModel.isSwitchingBranch)
                    }
                }
            } label: {
                Label(gitPanelViewModel.isSwitchingBranch ? "切换中..." : "切换分支", systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .accessibilityIdentifier("git.branch.menu")
            .disabled(gitPanelViewModel.availableBranches.isEmpty)

            Spacer(minLength: 0)
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

    private func statPill(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var activeErrorMessage: String? {
        gitPanelViewModel.branchActionError ?? gitPanelViewModel.loadError
    }
}