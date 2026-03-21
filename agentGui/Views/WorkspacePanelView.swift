//
//  WorkspacePanelView.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit

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
            workspaceActionBar
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
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(treeViewModel.currentDirectory?.lastPathComponent ?? "无工作目录")
                .font(.caption)
                .foregroundStyle(treeViewModel.currentDirectory == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: chooseDirectory) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("选择工作目录")
            .accessibilityIdentifier("workspace.chooseDirectoryButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // .background(.bar)
        .accessibilityIdentifier("workspace.selector")
    }

    private var workspaceActionBar: some View {
        HStack(spacing: 8) {
            searchControl

            Menu {
                Button("在访达中打开") {
                    treeViewModel.revealSelectionInFinder()
                }
                .disabled(!treeViewModel.hasSelection)

                Button("复制相对路径") {
                    copySelectionRelativePaths()
                }
                .disabled(!treeViewModel.hasSelection)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("批量操作")
            .help("批量操作")
            .accessibilityIdentifier("workspace.selectionActionsButton")

            Button(action: { treeViewModel.beginCreate(kind: .file, from: treeViewModel.selectedNode()) }) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(treeViewModel.currentDirectory == nil)
            .accessibilityLabel("新建文件")
            .help("新建文件")
            .accessibilityIdentifier("workspace.newFileButton")

            Button(action: { treeViewModel.beginCreate(kind: .folder, from: treeViewModel.selectedNode()) }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(treeViewModel.currentDirectory == nil)
            .accessibilityLabel("新建文件夹")
            .help("新建文件夹")
            .accessibilityIdentifier("workspace.newFolderButton")

            Button(action: { treeViewModel.beginRename(for: treeViewModel.selectedNode()) }) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(treeViewModel.selectedNode() == nil || treeViewModel.hasMultipleSelection)
            .accessibilityLabel("重命名")
            .help("重命名")
            .accessibilityIdentifier("workspace.renameButton")

            Button(role: .destructive, action: { treeViewModel.confirmDelete(nil) }) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!treeViewModel.hasSelection)
            .accessibilityLabel("删除")
            .help("删除")
            .accessibilityIdentifier("workspace.deleteButton")

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // .background(.bar)
        .accessibilityIdentifier("workspace.actionBar")
    }

    @ViewBuilder
    private var searchControl: some View {
        if treeViewModel.searchPresentationState == .expanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文件或文件夹", text: $treeViewModel.treeSearchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        treeViewModel.openSingleSearchResultIfPossible(workspaceState: workspaceState)
                    }
                    .accessibilityIdentifier("workspace.searchField")
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        treeViewModel.collapseSearch()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace.searchCollapseButton")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .onExitCommand {
                withAnimation(.easeInOut(duration: 0.18)) {
                    treeViewModel.collapseSearch()
                }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    treeViewModel.expandSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("展开搜索")
            .help("搜索文件或文件夹")
            .accessibilityIdentifier("workspace.searchToggleButton")
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeContent: some View {
        let filteredNodes = treeViewModel.filteredNodes()

        if treeViewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if treeViewModel.currentDirectory == nil {
            emptyState
        } else if filteredNodes.isEmpty {
            searchEmptyState
        } else {
            WorkspaceTreeView(
                nodes: filteredNodes,
                selectionIDs: treeViewModel.selectedTreeNodeIDs,
                primarySelectionID: treeViewModel.primarySelectionID,
                inlineEdit: treeViewModel.inlineEdit,
                expandsMatchingBranches: !treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                gitChangeProvider: { node in
                    treeViewModel.gitChangeMatch(for: node, snapshot: gitPanelViewModel.snapshot)
                },
                onSelectionChange: { ids, primaryID in
                    treeViewModel.applyOutlineSelection(ids: ids, primaryID: primaryID, workspaceState: workspaceState)
                },
                actions: workspaceTreeActions
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("无工作目录")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("点击右上角选择目录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前目录为空" : "未找到匹配项")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(treeViewModel.treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "使用上方按钮创建文件或文件夹" : "尝试更换关键字或清空搜索")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workspace.searchEmptyState")
    }

    // MARK: - Actions

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择工作目录"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        treeViewModel.setDirectory(url.standardizedFileURL) { directory in
            await gitPanelViewModel.refresh(for: directory, workspaceState: workspaceState)
        }
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings.workingDirectory = url.path
        do {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: "工作目录未成功保存"
            )
        } catch {
            return
        }
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

    private var workspaceTreeActions: WorkspaceTreeOutlineView.ActionHandlers {
        WorkspaceTreeOutlineView.ActionHandlers(
            previewDiff: { change, staged in
                Task {
                    await gitPanelViewModel.selectDiff(for: change, staged: staged, workspaceState: workspaceState)
                }
            },
            revealInFinder: { _ in
                treeViewModel.revealSelectionInFinder()
            },
            copyRelativePath: { _ in
                copySelectionRelativePaths()
            },
            newFile: { node in
                treeViewModel.applyOutlineSelection(
                    ids: [node.id.standardizedFileURL],
                    primaryID: node.id.standardizedFileURL,
                    workspaceState: workspaceState
                )
                treeViewModel.beginCreate(kind: .file, from: node)
            },
            newFolder: { node in
                treeViewModel.applyOutlineSelection(
                    ids: [node.id.standardizedFileURL],
                    primaryID: node.id.standardizedFileURL,
                    workspaceState: workspaceState
                )
                treeViewModel.beginCreate(kind: .folder, from: node)
            },
            rename: { node in
                treeViewModel.applyOutlineSelection(
                    ids: [node.id.standardizedFileURL],
                    primaryID: node.id.standardizedFileURL,
                    workspaceState: workspaceState
                )
                treeViewModel.beginRename(for: node)
            },
            delete: { node in
                treeViewModel.confirmDelete(treeViewModel.hasMultipleSelection ? nil : node)
            },
            canMoveSelection: { node in
                treeViewModel.canMoveSelection(to: node)
            },
            moveSelection: { node in
                treeViewModel.moveSelection(to: node, workspaceState: workspaceState)
            },
            newFileFromSelection: {
                treeViewModel.beginCreateFromSelection(kind: .file)
            },
            newFolderFromSelection: {
                treeViewModel.beginCreateFromSelection(kind: .folder)
            },
            renameSelection: {
                treeViewModel.beginRenameFromSelection()
            },
            deleteSelection: {
                treeViewModel.confirmDeleteSelection()
            },
            copySelectionRelativePaths: {
                copySelectionRelativePaths()
            },
            revealSelectionInFinder: {
                treeViewModel.revealSelectionInFinder()
            },
            inlineEditChange: { updatedName in
                guard let inlineEdit = treeViewModel.inlineEdit else { return }
                treeViewModel.inlineEdit = inlineEdit.withDraftName(updatedName)
            },
            inlineEditCommit: {
                treeViewModel.commitInlineEdit(workspaceState: workspaceState)
            },
            inlineEditCancel: {
                treeViewModel.cancelInlineEdit()
            }
        )
    }
}

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}
