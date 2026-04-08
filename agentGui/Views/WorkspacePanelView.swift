//
//  WorkspacePanelView.swift
//  agentGui
//

import SwiftUI
import SwiftData

// MARK: - WorkspacePanelView

/// 左侧文件浏览器面板
struct WorkspacePanelView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext
    private let launchOptions = TestLaunchOptions.current

    // MARK: - State

    @State private var treeViewModel = WorkspaceTreeViewModel()

    // MARK: - Body

    var body: some View {
        @Bindable var treeViewModel = treeViewModel

        VStack(spacing: 0) {
            directoryBar
            treeContent
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("panel.workspace")
        .onAppear {
            let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
            treeViewModel.loadFromWorkspaceState(
                workspaceState: workspaceState,
                globalWorkingDirectory: settings.workingDirectory,
                refreshGit: { url in
                    await gitPanelViewModel.refresh(for: url, workspaceState: workspaceState)
                }
            )
            treeViewModel.compactFolders = settings.compactFolders
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedSession?.persistentModelID) { _, _ in
            let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
            treeViewModel.loadFromWorkspaceState(
                workspaceState: workspaceState,
                globalWorkingDirectory: settings.workingDirectory,
                refreshGit: { url in
                    await gitPanelViewModel.refresh(for: url, workspaceState: workspaceState)
                }
            )
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedFile) { _, _ in
            treeViewModel.syncSelection(with: workspaceState.selectedFile)
            triggerWorkspaceLSPBootstrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceDirectorySelectionCoordinator.requestNotification)) { _ in
            chooseDirectory()
        }
        .alert("删除项目", isPresented: Binding(
            get: { treeViewModel.pendingDeleteNode != nil },
            set: { if !$0 { treeViewModel.clearPendingDelete() } }
        ), presenting: treeViewModel.pendingDeleteNode) { node in
            Button("取消", role: .cancel) {
                treeViewModel.clearPendingDelete()
            }
            Button("删除", role: .destructive) {
                treeViewModel.deletePendingNode(workspaceState: workspaceState)
            }
        } message: { node in
            if treeViewModel.pendingDeleteSelectionCount > 1 {
                Text("确定要删除选中的 \(treeViewModel.pendingDeleteSelectionCount) 个项目吗？此操作不可撤销。")
            } else {
                Text("确定要删除「\(node.name)」吗？此操作不可撤销。")
            }
        }
        .alert("错误", isPresented: Binding(
            get: { treeViewModel.errorMessage != nil },
            set: { if !$0 { treeViewModel.errorMessage = nil } }
        )) {
            Button("确定") { treeViewModel.errorMessage = nil }
        } message: {
            if let errorMessage = treeViewModel.errorMessage { Text(errorMessage) }
        }
    }

    // MARK: - Top directory bar

    private var directoryBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchControl
            workspaceActionBar
        }
        .padding(.horizontal, WorkbenchSidebarPanelStyle.layoutPadding)
        .padding(.top, WorkbenchSidebarPanelStyle.layoutPadding)
        .padding(.bottom, WorkbenchSidebarPanelStyle.compactSpacing)
        .accessibilityIdentifier("workspace.selector")
    }

    private var workspaceActionBar: some View {
        HStack(spacing: 10) {
            Label(selectionHintText, systemImage: selectionHintSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Menu {
                Button("新建文件") {
                    treeViewModel.beginCreate(kind: .file, from: treeViewModel.selectedNode())
                }

                Button("新建文件夹") {
                    treeViewModel.beginCreate(kind: .folder, from: treeViewModel.selectedNode())
                }
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(treeViewModel.currentDirectory == nil)
            .help("创建文件或文件夹")
            .accessibilityIdentifier("workspace.createMenuButton")

            Menu {
                Button("在访达中打开") {
                    treeViewModel.revealSelectionInFinder()
                }
                .disabled(!treeViewModel.hasSelection)

                Button("复制相对路径") {
                    copySelectionRelativePaths()
                }
                .disabled(!treeViewModel.hasSelection)

                Divider()

                Button("重命名") {
                    treeViewModel.beginRename(for: treeViewModel.selectedNode())
                }
                .disabled(treeViewModel.selectedNode() == nil || treeViewModel.hasMultipleSelection)

                Button("删除", role: .destructive) {
                    treeViewModel.confirmDelete(nil)
                }
                .disabled(!treeViewModel.hasSelection)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("更多操作")
            .help("显示更多文件操作")
            .accessibilityIdentifier("workspace.selectionActionsButton")

            if launchOptions.isUITestMode {
                Text("workspace.searchPresentation.\(treeViewModel.searchPresentationState == .expanded ? "expanded" : "collapsed")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.searchPresentation")
                Text("workspace.searchState.\(treeViewModel.searchStateText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.searchState")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: WorkbenchSidebarPanelStyle.controlHeight)
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: WorkbenchSidebarPanelStyle.controlCornerRadius,
                style: .continuous
            )
        )
        .accessibilityIdentifier("workspace.actionBar")
    }

    private var searchControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("过滤文件和文件夹", text: $treeViewModel.treeSearchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    treeViewModel.openSingleSearchResultIfPossible(workspaceState: workspaceState)
                }
                .accessibilityIdentifier("workspace.searchField")

            if !treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    treeViewModel.treeSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace.searchClearButton")
            }
        }
        .workbenchSidebarHeaderFieldStyle()
        .onExitCommand {
            treeViewModel.treeSearchText = ""
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeContent: some View {
        if treeViewModel.currentDirectory == nil {
            emptyState
        } else {
            FileTreeContainerView(
                directory: treeViewModel.currentDirectory,
                onOpenFile: { id in
                    workspaceState.selectedFile = id.url
                },
                onPrimarySelectionChange: { url in
                    workspaceState.selectedFile = url
                }
            )
            .padding(.horizontal, WorkbenchSidebarPanelStyle.layoutPadding)
            .padding(.bottom, WorkbenchSidebarPanelStyle.layoutPadding)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        WorkbenchSidebarEmptyStateView(
            systemImage: "folder",
            title: "无工作目录",
            message: "从\"文件\"菜单打开或切换工作区"
        )
    }

    private var searchEmptyState: some View {
        WorkbenchSidebarEmptyStateView(
            systemImage: treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "folder" : "magnifyingglass",
            title: treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前目录为空" : "未找到匹配项",
            message: treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "使用上方\"新建\"菜单创建文件或文件夹" : "尝试更换关键字或清空搜索"
        )
        .accessibilityIdentifier("workspace.searchEmptyState")
    }

    // MARK: - Actions

    private func chooseDirectory() {
        guard let url = WorkspaceDirectorySelectionCoordinator.presentOpenPanel() else { return }
        guard WorkspaceDirectorySelectionCoordinator.applySelection(
            url,
            workspaceState: workspaceState,
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator,
            userMessage: "工作目录未成功保存"
        ) else {
            treeViewModel.errorMessage = "工作目录未成功保存"
            return
        }

        treeViewModel.setDirectory(url) { directory in
            await gitPanelViewModel.refresh(for: directory, workspaceState: workspaceState)
        }
        triggerWorkspaceLSPBootstrap()
    }

    private func triggerWorkspaceLSPBootstrap() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let workingDirectory = treeViewModel.currentDirectory?.path ?? workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        let selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        Task {
            _ = try? await claudeService.ensureWorkspaceLSPState(
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath,
                settings: settings
            )
        }
    }

    @discardableResult
    private func persistSettingsMutation(userMessage: String, mutation: () -> Void) -> Bool {
        mutation()

        do {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: userMessage
            )
            return true
        } catch {
            treeViewModel.errorMessage = userMessage
            return false
        }
    }

    private func copySelectionRelativePaths() {
        let relativePaths = treeViewModel.relativePathsForSelection()
        guard !relativePaths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePaths.sorted().joined(separator: "\n"), forType: .string)
    }

    private var selectionHintText: String {
        if let selectionSummaryText = treeViewModel.selectionSummaryText {
            return selectionSummaryText
        }

        if treeViewModel.currentDirectory == nil {
            return "从\"文件\"菜单打开工作区。"
        }

        return "右键文件查看更多操作。"
    }

    private var selectionHintSymbol: String {
        if treeViewModel.hasMultipleSelection {
            return "checklist"
        }

        if treeViewModel.hasSelection {
            return "checkmark.circle"
        }

        return treeViewModel.currentDirectory == nil ? "folder.badge.questionmark" : "cursorarrow.click"
    }


}

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}
