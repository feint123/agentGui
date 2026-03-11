import SwiftUI

struct GitPanelView: View {
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(WorkspaceState.self) private var workspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let snapshot = gitPanelViewModel.snapshot {
                summary(snapshot)
                changeSections(snapshot)
                commitComposer
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
        .background(Color.primary.opacity(0.03))
        .confirmationDialog(
            pendingActionTitle,
            isPresented: Binding(
                get: { gitPanelViewModel.pendingDangerousAction != nil },
                set: { if !$0 { gitPanelViewModel.pendingDangerousAction = nil } }
            )
        ) {
            Button("确认", role: .destructive) {
                Task { await gitPanelViewModel.confirmPendingAction() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pendingActionMessage)
        }
        .alert(
            "Git 操作失败",
            isPresented: Binding(
                get: { gitPanelViewModel.loadError != nil && gitPanelViewModel.snapshot != nil },
                set: { if !$0 { gitPanelViewModel.loadError = nil } }
            )
        ) {
            Button("确定") { gitPanelViewModel.loadError = nil }
        } message: {
            Text(gitPanelViewModel.loadError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Git", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Button {
                guard let workingDirectory = gitPanelViewModel.currentWorkingDirectory else { return }
                Task { await gitPanelViewModel.refresh(for: workingDirectory) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(gitPanelViewModel.currentWorkingDirectory == nil || gitPanelViewModel.isLoading)
        }
    }

    private func summary(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.repositoryName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(snapshot.branchName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                statPill("Staged", count: snapshot.stagedChanges.count)
                statPill("Modified", count: snapshot.unstagedChanges.count)
                statPill("Untracked", count: snapshot.untrackedChanges.count)
            }

            if snapshot.hasRemoteTrackingBranch {
                Text("Ahead \(snapshot.aheadCount) · Behind \(snapshot.behindCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let banner = gitPanelViewModel.transientBanner, !banner.isEmpty {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if snapshot.stagedChanges.isEmpty && snapshot.unstagedChanges.isEmpty && snapshot.untrackedChanges.isEmpty {
                Text("工作区干净")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func changeSections(_ snapshot: GitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.stagedChanges.isEmpty {
                changeSection(title: "Staged", changes: snapshot.stagedChanges, staged: true)
            }
            if !snapshot.unstagedChanges.isEmpty {
                changeSection(title: "Modified", changes: snapshot.unstagedChanges, staged: false)
            }
            if !snapshot.untrackedChanges.isEmpty {
                changeSection(title: "Untracked", changes: snapshot.untrackedChanges, staged: false)
            }
        }
    }

    private func changeSection(title: String, changes: [GitFileChange], staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Task { await gitPanelViewModel.selectDiff(for: change, staged: staged, workspaceState: workspaceState) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(change.statusBadge)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(change.relativePath)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        if staged {
                            smallAction("取消暂存") {
                                Task { await gitPanelViewModel.unstage(change) }
                            }
                        } else if change.section == .untracked {
                            smallAction("暂存") {
                                Task { await gitPanelViewModel.stage(change) }
                            }
                            smallAction("删除", role: .destructive) {
                                gitPanelViewModel.requestClean(change)
                            }
                        } else {
                            smallAction("暂存") {
                                Task { await gitPanelViewModel.stage(change) }
                            }
                            smallAction("丢弃", role: .destructive) {
                                gitPanelViewModel.requestDiscard(change)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if title != "Staged" && (!changes.isEmpty) {
                smallAction("全部暂存") {
                    Task { await gitPanelViewModel.stageAll() }
                }
            }
        }
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("输入提交信息", text: Bindable(gitPanelViewModel).commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer(minLength: 0)
                Button("提交") {
                    Task { await gitPanelViewModel.commit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!gitPanelViewModel.canCommit || gitPanelViewModel.isLoading)
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前目录不是 Git 仓库")
                .font(.caption.weight(.medium))
            Text("切换到仓库目录后，这里会显示分支、变更和提交入口。")
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

    private func smallAction(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(title, role: role, action: action)
            .buttonStyle(.borderless)
            .font(.caption)
    }

    private var pendingActionTitle: String {
        switch gitPanelViewModel.pendingDangerousAction {
        case .discard:
            return "确认丢弃改动"
        case .clean:
            return "确认删除未跟踪文件"
        case nil:
            return "确认操作"
        }
    }

    private var pendingActionMessage: String {
        guard let action = gitPanelViewModel.pendingDangerousAction else { return "" }
        switch action {
        case .discard(let change):
            return "将撤销 \(change.relativePath) 的未暂存改动。"
        case .clean(let change):
            return "将删除未跟踪文件 \(change.relativePath)。"
        }
    }
}

private extension GitFileChange {
    var statusBadge: String {
        switch status {
        case .added:
            return "A"
        case .modified:
            return "M"
        case .deleted:
            return "D"
        case .renamed:
            return "R"
        case .untracked:
            return "?"
        }
    }
}