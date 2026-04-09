import SwiftUI

struct GitSidebarChangesSection: View {
    let sidebarViewModel: GitSidebarViewModel
    let workspaceState: WorkspaceState

    @FocusState private var isListFocused: Bool

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
        .focusable()
        .focused($isListFocused)
        .onKeyPress(.upArrow) {
            moveKeyboardSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveKeyboardSelection(by: 1)
            return .handled
        }
    }

    /// 所有变更的统一有序列表（staged → unstaged → untracked），用于键盘 ↑↓ 导航。
    private var allChangesForKeyboard: [GitFileChange] {
        sidebarViewModel.filteredStagedChanges
            + sidebarViewModel.filteredUnstagedChanges
            + sidebarViewModel.filteredUntrackedChanges
    }

    private func moveKeyboardSelection(by delta: Int) {
        let all = allChangesForKeyboard
        guard !all.isEmpty else { return }
        let currentID = sidebarViewModel.selectedChangeID
        let currentIndex = all.firstIndex(where: { $0.id == currentID }) ?? -1
        let nextIndex = max(0, min(all.count - 1, currentIndex + delta))
        let nextChange = all[nextIndex]
        Task {
            await sidebarViewModel.selectChange(nextChange, workspaceState: workspaceState)
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
        let isSelected = sidebarViewModel.selectedChangeID == change.id

        return VStack(alignment: .leading, spacing: 6) {
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
        .padding(.horizontal, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.15)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await sidebarViewModel.selectChange(change, workspaceState: workspaceState)
            }
        }
    }
}

// MARK: - ChangeRowView
/// 单个文件变更行：非 hover 时仅显示状态徽章；hover 时显示快捷操作图标。
private struct ChangeRowView: View {
    let change: GitFileChange
    let isSelected: Bool
    /// SF Symbol 名称，主操作按钮（stage / unstage）。
    let primarySymbol: String
    let primaryAction: () -> Void
    /// 仅 unstaged 区传入（丢弃）；默认 nil。
    var discardAction: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(change.relativePath)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                hoverIcons
            } else {
                Text(change.status.statusBadgeText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            // 行点击逻辑由外部 changeGroup 处理（CL-A1 已实现）
        }
    }

    @ViewBuilder
    private var hoverIcons: some View {
        HStack(spacing: 4) {
            if let discardAction {
                Button(action: discardAction) {
                    Image(systemName: "trash")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("丢弃更改")
            }
            Button(action: primaryAction) {
                Image(systemName: primarySymbol)
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .help(change.section == .staged ? "取消暂存" : "暂存")
        }
    }
}