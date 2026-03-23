import SwiftUI

struct GitSidebarChangesSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    var body: some View {
        @Bindable var sidebarViewModel = sidebarViewModel

        return sectionCard("变更", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("过滤文件", text: $sidebarViewModel.changeFilterText)
                    .textFieldStyle(.roundedBorder)

                if sidebarViewModel.filteredStagedChanges.isEmpty && sidebarViewModel.filteredUnstagedChanges.isEmpty && sidebarViewModel.filteredUntrackedChanges.isEmpty {
                    Text("没有匹配的变更")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if !sidebarViewModel.filteredStagedChanges.isEmpty {
                        changeGroup(
                            title: "已暂存",
                            changes: sidebarViewModel.filteredStagedChanges,
                            primaryActionTitle: "取消暂存",
                            primaryAction: { change in
                                Task { await sidebarViewModel.panelViewModel.unstage(change: change, workspaceState: workspaceState) }
                            }
                        )
                    }

                    if !sidebarViewModel.filteredUnstagedChanges.isEmpty {
                        changeGroup(
                            title: "未暂存",
                            changes: sidebarViewModel.filteredUnstagedChanges,
                            primaryActionTitle: "暂存",
                            primaryAction: { change in
                                Task { await sidebarViewModel.panelViewModel.stage(change: change, workspaceState: workspaceState) }
                            },
                            secondaryActionTitle: "丢弃",
                            secondaryAction: { change in
                                sidebarViewModel.requestDiscard(change)
                            }
                        )
                    }

                    if !sidebarViewModel.filteredUntrackedChanges.isEmpty {
                        changeGroup(
                            title: "未跟踪",
                            changes: sidebarViewModel.filteredUntrackedChanges,
                            primaryActionTitle: "暂存",
                            primaryAction: { change in
                                Task { await sidebarViewModel.panelViewModel.stage(change: change, workspaceState: workspaceState) }
                            }
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "确认丢弃更改？",
            isPresented: Binding(
                get: { sidebarViewModel.pendingDiscardChange != nil },
                set: { isPresented in
                    if !isPresented {
                        sidebarViewModel.cancelDiscard()
                    }
                }
            ),
            presenting: sidebarViewModel.pendingDiscardChange
        ) { change in
            Button("丢弃更改", role: .destructive) {
                Task { await sidebarViewModel.confirmDiscard(workspaceState: workspaceState) }
            }
            Button("取消", role: .cancel) {
                sidebarViewModel.cancelDiscard()
            }
        } message: { change in
            Text(change.relativePath)
        }
    }

    private func changeGroup(
        title: String,
        changes: [GitFileChange],
        primaryActionTitle: String,
        primaryAction: @escaping (GitFileChange) -> Void,
        secondaryActionTitle: String? = nil,
        secondaryAction: ((GitFileChange) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(changes) { change in
                changeRow(
                    change: change,
                    primaryActionTitle: primaryActionTitle,
                    primaryAction: primaryAction,
                    secondaryActionTitle: secondaryActionTitle,
                    secondaryAction: secondaryAction
                )
            }
        }
    }

    private func changeRow(
        change: GitFileChange,
        primaryActionTitle: String,
        primaryAction: @escaping (GitFileChange) -> Void,
        secondaryActionTitle: String? = nil,
        secondaryAction: ((GitFileChange) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.relativePath)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(change.status.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("查看 Diff") {
                    Task {
                        await sidebarViewModel.panelViewModel.selectDiff(
                            for: change,
                            staged: change.section == .staged,
                            workspaceState: workspaceState
                        )
                    }
                }
                .buttonStyle(.borderless)

                Button(primaryActionTitle) {
                    primaryAction(change)
                }
                .buttonStyle(.borderless)

                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, role: .destructive) {
                        secondaryAction(change)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}