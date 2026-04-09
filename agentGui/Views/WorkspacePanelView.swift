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

    @State private var fileTreeViewModel = FileTreeViewModel()

    // MARK: - Body

    var body: some View {
        @Bindable var fileTreeViewModel = fileTreeViewModel

        VStack(spacing: 0) {
            directoryBar
            treeContent
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("panel.workspace")
        .onAppear {
            loadDirectoryFromWorkspaceState()
            let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
            Task { await fileTreeViewModel.setCompactFolders(settings.compactFolders) }
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedSession?.persistentModelID) { _, _ in
            loadDirectoryFromWorkspaceState()
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedFile) { _, _ in
            fileTreeViewModel.syncSelection(fileURL: workspaceState.selectedFile)
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: fileTreeViewModel.rootDirectory) { _, newDirectory in
            guard let newDirectory else { return }
            Task { await gitPanelViewModel.refresh(for: newDirectory, workspaceState: workspaceState) }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceDirectorySelectionCoordinator.requestNotification)) { _ in
            chooseDirectory()
        }
        .alert("错误", isPresented: Binding(
            get: { fileTreeViewModel.errorMessage != nil },
            set: { if !$0 { fileTreeViewModel.errorMessage = nil } }
        )) {
            Button("确定") { fileTreeViewModel.errorMessage = nil }
        } message: {
            if let errorMessage = fileTreeViewModel.errorMessage { Text(errorMessage) }
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
                    Task {
                        await fileTreeViewModel.beginCreate(InlineEditSession.Kind.createFile, near: fileTreeViewModel.selection.primary)
                    }
                }

                Button("新建文件夹") {
                    Task {
                        await fileTreeViewModel.beginCreate(InlineEditSession.Kind.createFolder, near: fileTreeViewModel.selection.primary)
                    }
                }
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(fileTreeViewModel.rootDirectory == nil)
            .help("创建文件或文件夹")
            .accessibilityIdentifier("workspace.createMenuButton")

            Menu {
                Button("在访达中打开") {
                    fileTreeViewModel.revealInFinder(ids: Array(fileTreeViewModel.selection.selected))
                }
                .disabled(!fileTreeViewModel.hasSelection)

                Button("复制相对路径") {
                    fileTreeViewModel.copyRelativePath(ids: Array(fileTreeViewModel.selection.selected))
                }
                .disabled(!fileTreeViewModel.hasSelection)

                Divider()

                Button("重命名") {
                    guard let primary = fileTreeViewModel.selection.primary else { return }
                    Task { await fileTreeViewModel.beginRename(primary) }
                }
                .disabled(fileTreeViewModel.selection.primary == nil || fileTreeViewModel.hasMultipleSelection)

                Button("删除", role: .destructive) {
                    fileTreeViewModel.beginDelete(ids: Set(fileTreeViewModel.selection.selected))
                }
                .disabled(!fileTreeViewModel.hasSelection)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("更多操作")
            .help("显示更多文件操作")
            .accessibilityIdentifier("workspace.selectionActionsButton")

            if launchOptions.isUITestMode {
                Text("workspace.searchPresentation.\(fileTreeViewModel.searchPresentationState == .expanded ? "expanded" : "collapsed")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.searchPresentation")
                Text("workspace.searchState.\(fileTreeViewModel.searchStateText)")
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

            TextField("过滤文件和文件夹", text: $fileTreeViewModel.searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    fileTreeViewModel.openSingleSearchResult { url in
                        workspaceState.selectedFile = url
                    }
                }
                .accessibilityIdentifier("workspace.searchField")

            if !fileTreeViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    fileTreeViewModel.searchText = ""
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
            fileTreeViewModel.searchText = ""
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeContent: some View {
        if fileTreeViewModel.rootDirectory == nil {
            emptyState
        } else {
            FileTreeContainerView(
                viewModel: fileTreeViewModel,
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

    // MARK: - Actions

    private func loadDirectoryFromWorkspaceState() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        let url = dir.isEmpty ? nil : URL(fileURLWithPath: dir).standardizedFileURL
        guard url != fileTreeViewModel.rootDirectory else { return }
        Task { await fileTreeViewModel.setDirectory(url) }
        if fileTreeViewModel.selection.primary == nil {
            fileTreeViewModel.syncSelection(fileURL: workspaceState.selectedFile)
        }
    }

    private func chooseDirectory() {
        guard let url = WorkspaceDirectorySelectionCoordinator.presentOpenPanel() else { return }
        guard WorkspaceDirectorySelectionCoordinator.applySelection(
            url,
            workspaceState: workspaceState,
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator,
            userMessage: "工作目录未成功保存"
        ) else {
            fileTreeViewModel.errorMessage = "工作目录未成功保存"
            return
        }

        Task { await fileTreeViewModel.setDirectory(url) }
        triggerWorkspaceLSPBootstrap()
    }

    private func triggerWorkspaceLSPBootstrap() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let workingDirectory = fileTreeViewModel.rootDirectory?.path
            ?? workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        let selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        Task {
            _ = try? await claudeService.ensureWorkspaceLSPState(
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath,
                settings: settings
            )
        }
    }

    private var selectionHintText: String {
        if let summary = fileTreeViewModel.selectionSummaryText {
            return summary
        }
        if fileTreeViewModel.rootDirectory == nil {
            return "从\"文件\"菜单打开工作区。"
        }
        return "右键文件查看更多操作。"
    }

    private var selectionHintSymbol: String {
        if fileTreeViewModel.hasMultipleSelection { return "checklist" }
        if fileTreeViewModel.hasSelection { return "checkmark.circle" }
        return fileTreeViewModel.rootDirectory == nil ? "folder.badge.questionmark" : "cursorarrow.click"
    }

}

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}
