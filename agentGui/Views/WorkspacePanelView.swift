//
//  WorkspacePanelView.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - FileNode

/// 文件树中的一个节点（文件或目录）
struct FileNode: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    /// `nil` = 叶节点（文件）；非nil = 可展开的目录
    var children: [FileNode]?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
}

// MARK: - WorkspacePanelView

/// 左侧文件浏览器面板
struct WorkspacePanelView: View {

    // MARK: - Environment

    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ClaudeService.self) private var claudeService
    @Environment(GitPanelViewModel.self) private var gitPanelViewModel
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    private let launchOptions = TestLaunchOptions.current

    // MARK: - State

    @State private var rootNodes: [FileNode] = []
    @State private var currentDirectory: URL?
    @State private var isLoading = false
    @State private var refreshCoordinator = WorkspaceTreeRefreshCoordinator()
    @State private var showsLSPDiagnosticsPopover = false
    @State private var showsLSPManagementPopover = false
    @State private var treeSearchText = ""
    @State private var selectedTreeNodeID: URL?
    @State private var inlineEdit: WorkspaceTreeInlineEdit?
    @State private var pendingDeleteNode: FileNode?
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            directoryBar
            workspaceActionBar
            GitPanelView()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            Divider()
                .opacity(0.4)
            treeContent
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
                .opacity(0.4)
            lspStatusFooter
        }
        .accessibilityIdentifier("panel.workspace")
        .onAppear {
            configureRefreshCoordinator()
            loadFromWorkspaceState()
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedSession?.persistentModelID) { _, _ in
            loadFromWorkspaceState()
            triggerWorkspaceLSPBootstrap()
        }
        .onChange(of: workspaceState.selectedFile) { _, _ in
            selectedTreeNodeID = workspaceState.selectedFile
            triggerWorkspaceLSPBootstrap()
        }
        .alert("删除项目", isPresented: Binding(
            get: { pendingDeleteNode != nil },
            set: { if !$0 { pendingDeleteNode = nil } }
        ), presenting: pendingDeleteNode) { node in
            Button("取消", role: .cancel) {
                pendingDeleteNode = nil
            }
            Button("删除", role: .destructive) {
                deleteNode(node)
            }
        } message: { node in
            Text("确定要删除「\(node.name)」吗？此操作不可撤销。")
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    // MARK: - Top directory bar

    private var directoryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(currentDirectory?.lastPathComponent ?? "无工作目录")
                .font(.caption)
                .foregroundStyle(currentDirectory == nil ? .tertiary : .primary)
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文件或文件夹", text: $treeSearchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("workspace.searchField")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            Button(action: { beginCreate(kind: .file, from: selectedNode) }) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(currentDirectory == nil)
            .accessibilityLabel("新建文件")
            .help("新建文件")
            .accessibilityIdentifier("workspace.newFileButton")

            Button(action: { beginCreate(kind: .folder, from: selectedNode) }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(currentDirectory == nil)
            .accessibilityLabel("新建文件夹")
            .help("新建文件夹")
            .accessibilityIdentifier("workspace.newFolderButton")

            Button(action: { beginRename(for: selectedNode) }) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(selectedNode == nil)
            .accessibilityLabel("重命名")
            .help("重命名")
            .accessibilityIdentifier("workspace.renameButton")

            Button(role: .destructive, action: { pendingDeleteNode = selectedNode }) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(selectedNode == nil)
            .accessibilityLabel("删除")
            .help("删除")
            .accessibilityIdentifier("workspace.deleteButton")

            if launchOptions.isUITestMode {
                Text("workspace.searchState.\(searchStateText)")
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

    // MARK: - Tree

    @ViewBuilder
    private var treeContent: some View {
        let displayNodes = nodesForDisplay()
        let filteredNodes = WorkspaceTreeSnapshotOps.filterNodes(displayNodes, query: treeSearchText)

        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentDirectory == nil {
            emptyState
        } else if filteredNodes.isEmpty {
            searchEmptyState
        } else {
            List(filteredNodes, children: \.optionalChildren) { node in
                let gitChange = gitChangeMatch(for: node)
                FileRowView(
                    node: node,
                    isSelected: selectedTreeNodeID == node.id || (!node.isDirectory && workspaceState.selectedFile == node.id),
                    gitChange: gitChange,
                    onPreviewDiff: { change, staged in
                        Task { await gitPanelViewModel.selectDiff(for: change, staged: staged, workspaceState: workspaceState) }
                    },
                    onNewFile: {
                        selectedTreeNodeID = node.id
                        beginCreate(kind: .file, from: node)
                    },
                    onNewFolder: {
                        selectedTreeNodeID = node.id
                        beginCreate(kind: .folder, from: node)
                    },
                    onRename: {
                        selectedTreeNodeID = node.id
                        beginRename(for: node)
                    },
                    onDelete: {
                        selectedTreeNodeID = node.id
                        pendingDeleteNode = node
                    },
                    inlineEdit: inlineEdit,
                    onInlineEditChange: { updatedName in
                        guard let inlineEdit else { return }
                        self.inlineEdit = inlineEdit.withDraftName(updatedName)
                    },
                    onInlineEditCommit: {
                        commitInlineEdit()
                    },
                    onInlineEditCancel: {
                        cancelInlineEdit()
                    }
                ) {
                    selectedTreeNodeID = node.id
                    if !node.isDirectory {
                        workspaceState.clearGitDiffSelection()
                        workspaceState.selectedFile = node.id
                    }
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("workspace.fileTree")
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
            Image(systemName: treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前目录为空" : "未找到匹配项")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "使用上方按钮创建文件或文件夹" : "尝试更换关键字或清空搜索")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workspace.searchEmptyState")
    }

    private var lspStatusFooter: some View {
        let _ = claudeService.lspPresentationRevision
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let status = claudeService.makeWorkspacePanelLSPStatus(
            workingDirectory: currentDirectory?.path ?? "",
            selectedFilePath: workspaceState.selectedFile?.standardizedFileURL.path,
            settings: settings
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("LSP")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(status.stateText)
                    .font(.caption)
                    .foregroundStyle(lspStateColor(status.stateText))
                    .lineLimit(1)
            }

            if let fileName = status.selectedFileName {
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Label(status.serverID ?? "未绑定", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    showsLSPManagementPopover.toggle()
                } label: {
                    Label("管理", systemImage: "slider.horizontal.3")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsLSPManagementPopover, arrowEdge: .bottom) {
                    LSPManagementPopoverView(
                        viewModel: lspManagementViewModel,
                        onOpenSettings: {
                            openWindow(id: SettingsWindowScene.id)
                            showsLSPManagementPopover = false
                        }
                    )
                }
            }

            HStack(spacing: 8) {
                Button {
                    showsLSPDiagnosticsPopover.toggle()
                } label: {
                    lspCountChip(title: "错误", count: status.errorCount, color: .red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsLSPDiagnosticsPopover, arrowEdge: .bottom) {
                    LSPDiagnosticsPopoverView(status: status)
                }

                Button {
                    showsLSPDiagnosticsPopover.toggle()
                } label: {
                    lspCountChip(title: "警告", count: status.warningCount, color: .orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // .background(.bar)
        .accessibilityIdentifier("workspace.lspStatusFooter")
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
        setDirectory(url)
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

    private func setDirectory(_ url: URL) {
        currentDirectory = url.standardizedFileURL
        refreshCoordinator.setDirectory(currentDirectory)
        Task { await gitPanelViewModel.refresh(for: url, workspaceState: workspaceState) }
    }

    private func triggerWorkspaceLSPBootstrap() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let workingDirectory = currentDirectory?.path ?? workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        let selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        Task {
            _ = try? await claudeService.ensureWorkspaceLSPState(
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath,
                settings: settings
            )
        }
    }

    private func loadFromWorkspaceState() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: settings.workingDirectory)
        guard !dir.isEmpty else {
            rootNodes = []
            currentDirectory = nil
            selectedTreeNodeID = nil
            refreshCoordinator.setDirectory(nil)
            return
        }
        let url = URL(fileURLWithPath: dir).standardizedFileURL
        if url != currentDirectory {
            setDirectory(url)
        }
        if selectedTreeNodeID == nil {
            selectedTreeNodeID = workspaceState.selectedFile
        }
    }

    private func configureRefreshCoordinator() {
        refreshCoordinator.onNodesChanged = { nodes, loading in
            self.rootNodes = nodes
            self.isLoading = loading
        }
    }

    private var selectedNode: FileNode? {
        guard let selectedTreeNodeID else { return nil }
        return findNode(in: rootNodes, matching: selectedTreeNodeID)
    }

    private var searchStateText: String {
        if currentDirectory == nil {
            return "none"
        }
        let filteredNodes = WorkspaceTreeSnapshotOps.filterNodes(nodesForDisplay(), query: treeSearchText)
        return filteredNodes.isEmpty ? "empty" : "results"
    }

    private func nodesForDisplay() -> [FileNode] {
        WorkspaceTreeInlineEditApplier.apply(inlineEdit: inlineEdit, to: rootNodes, rootDirectory: currentDirectory)
    }

    private func findNode(in nodes: [FileNode], matching id: URL) -> FileNode? {
        for node in nodes {
            if node.id == id { return node }
            if let child = findNode(in: node.children ?? [], matching: id) {
                return child
            }
        }
        return nil
    }

    private func beginCreate(kind: WorkspaceTreeInlineEdit.Kind, from node: FileNode?) {
        guard let targetDirectory = targetDirectory(for: node) ?? currentDirectory else { return }
        treeSearchText = ""
        inlineEdit = WorkspaceTreeInlineEdit.makeCreate(kind: kind, targetDirectory: targetDirectory)
        selectedTreeNodeID = inlineEdit?.editingNodeID
    }

    private func beginRename(for node: FileNode?) {
        guard let node else { return }
        inlineEdit = WorkspaceTreeInlineEdit.makeRename(targetURL: node.id, initialName: node.name, isDirectory: node.isDirectory)
    }

    private func commitInlineEdit() {
        guard let inlineEdit else { return }
        do {
            switch inlineEdit.kind {
            case .file:
                let createdURL = try WorkspaceFileTreeOperations.createFile(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL
                workspaceState.clearGitDiffSelection()
                workspaceState.selectedFile = createdURL
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([inlineEdit.parentDirectory])
            case .folder:
                let createdURL = try WorkspaceFileTreeOperations.createDirectory(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([inlineEdit.parentDirectory])
            case .rename:
                guard let targetURL = inlineEdit.targetURL else { return }
                let renamedURL = try WorkspaceFileTreeOperations.renameItem(at: targetURL, to: inlineEdit.draftName)
                let oldParent = targetURL.deletingLastPathComponent()
                let newParent = renamedURL.deletingLastPathComponent()
                updateSelectionsAfterRename(from: targetURL, to: renamedURL)
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([oldParent, newParent])
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func cancelInlineEdit() {
        inlineEdit = nil
    }

    private func deleteNode(_ node: FileNode) {
        do {
            try WorkspaceFileTreeOperations.deleteItem(at: node.id)
            updateSelectionsAfterDeletion(of: node.id)
            pendingDeleteNode = nil
            refreshCoordinator.refreshDirectories([node.id.deletingLastPathComponent()])
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func targetDirectory(for node: FileNode?) -> URL? {
        guard let node else { return currentDirectory }
        return node.isDirectory ? node.id : node.id.deletingLastPathComponent()
    }

    private func updateSelectionsAfterRename(from originalURL: URL, to renamedURL: URL) {
        selectedTreeNodeID = remapSelectionURL(selectedTreeNodeID, from: originalURL, to: renamedURL)
        workspaceState.selectedFile = remapSelectionURL(workspaceState.selectedFile, from: originalURL, to: renamedURL)

        if let selectedDiffPath = workspaceState.selectedGitDiffPath,
           contains(originalURL, candidate: selectedDiffPath) {
            workspaceState.clearGitDiffSelection()
        }
    }

    private func updateSelectionsAfterDeletion(of deletedURL: URL) {
        if let selectedTreeNodeID, contains(deletedURL, candidate: selectedTreeNodeID) {
            self.selectedTreeNodeID = nil
        }
        if let selectedFile = workspaceState.selectedFile, contains(deletedURL, candidate: selectedFile) {
            workspaceState.selectedFile = nil
        }
        if let selectedDiffPath = workspaceState.selectedGitDiffPath, contains(deletedURL, candidate: selectedDiffPath) {
            workspaceState.clearGitDiffSelection()
        }
    }

    private func remapSelectionURL(_ candidate: URL?, from originalURL: URL, to renamedURL: URL) -> URL? {
        guard let candidate else { return nil }

        let originalPath = originalURL.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path

        if candidatePath == originalPath {
            return renamedURL.standardizedFileURL
        }
        guard candidatePath.hasPrefix(originalPath + "/") else {
            return candidate
        }

        let suffix = String(candidatePath.dropFirst(originalPath.count))
        return URL(fileURLWithPath: renamedURL.path + suffix).standardizedFileURL
    }

    private func contains(_ containerURL: URL, candidate: URL) -> Bool {
        let containerPath = containerURL.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
    }

    private func gitChangeMatch(for node: FileNode) -> GitFileChange? {
        guard !node.isDirectory, let snapshot = gitPanelViewModel.snapshot else { return nil }
        let relativePath = relativePath(for: node.id, root: snapshot.repositoryRoot)
        return (snapshot.stagedChanges + snapshot.unstagedChanges + snapshot.untrackedChanges)
            .first { $0.relativePath == relativePath }
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func lspStateColor(_ stateText: String) -> Color {
        LSPStatusPresentationTone.tone(for: stateText).color
    }

    private var lspManagementViewModel: LSPManagementViewModel {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)

        return LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(
                catalog: .builtInCatalog(),
                serverManager: claudeService.lspServerManager
            ),
            installCoordinator: claudeService.lspInstallCoordinator,
            serverManager: claudeService.lspServerManager,
            persistSettings: { userMessage, mutation in
                persistSettingsMutation(userMessage: userMessage, mutation: mutation)
            }
        )
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
            errorMessage = userMessage
            return false
        }
    }

    private func lspCountChip(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }
}

// MARK: - FileNode helper

private extension FileNode {
    var optionalChildren: [FileNode]? {
        guard isDirectory else { return nil }
        return children
    }
}

// MARK: - FileRowView

private struct FileRowView: View {
    let node: FileNode
    let isSelected: Bool
    let gitChange: GitFileChange?
    let onPreviewDiff: (GitFileChange, Bool) -> Void
    let onNewFile: () -> Void
    let onNewFolder: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let inlineEdit: WorkspaceTreeInlineEdit?
    let onInlineEditChange: (String) -> Void
    let onInlineEditCommit: () -> Void
    let onInlineEditCancel: () -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            if isInlineEditing {
                InlineTreeNameField(
                    text: Binding(
                        get: { inlineEdit?.draftName ?? node.name },
                        set: onInlineEditChange
                    ),
                    onCommit: onInlineEditCommit,
                    onCancel: onInlineEditCancel
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
            if let gitChange {
                Text(gitChange.statusBadge)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor(for: gitChange.status))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(statusColor(for: gitChange.status).opacity(isSelected || isHovered ? 0.16 : 0.08), in: Capsule())
                    .opacity(isSelected || isHovered ? 1 : 0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityIdentifier(node.isDirectory ? "workspace.directory.\(node.name)" : "workspace.file.\(node.name)")
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .contextMenu {
            if let gitChange {
                Button("查看 Diff") {
                    onPreviewDiff(gitChange, gitChange.section == .staged)
                }
                Divider()
            }
            Button("新建文件") {
                onNewFile()
            }
            Button("新建文件夹") {
                onNewFolder()
            }
            Button("重命名") {
                onRename()
            }
            Button("删除", role: .destructive) {
                onDelete()
            }
        }
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered  { return Color.primary.opacity(0.07) }
        return .clear
    }

    private var iconColor: Color {
        if node.isDirectory {
            return isSelected ? .accentColor : Color(nsColor: .systemOrange).opacity(0.85)
        }
        return isSelected ? Color.accentColor.opacity(0.8) : .secondary
    }

    private func fileIcon(for name: String) -> String {
        FileIconSymbolResolver.symbol(forFileName: name)
    }

    private func statusColor(for status: GitChangeStatus) -> Color {
        switch status {
        case .added, .untracked:
            return .green
        case .deleted:
            return .red
        case .renamed:
            return .orange
        case .modified:
            return .secondary
        }
    }

    private var isInlineEditing: Bool {
        inlineEdit?.editingNodeID == node.id
    }
}

private struct WorkspaceTreeInlineEdit: Equatable {
    enum Kind: Equatable {
        case file
        case folder
        case rename
    }

    let kind: Kind
    let parentDirectory: URL
    let targetURL: URL?
    let editingNodeID: URL
    let draftName: String
    let isDirectory: Bool

    static func makeCreate(kind: Kind, targetDirectory: URL) -> WorkspaceTreeInlineEdit {
        let tempURL = targetDirectory.appending(path: ".agentgui-inline-\(UUID().uuidString)")
        return WorkspaceTreeInlineEdit(
            kind: kind,
            parentDirectory: targetDirectory,
            targetURL: nil,
            editingNodeID: tempURL,
            draftName: "",
            isDirectory: kind == .folder
        )
    }

    static func makeRename(targetURL: URL, initialName: String, isDirectory: Bool) -> WorkspaceTreeInlineEdit {
        WorkspaceTreeInlineEdit(
            kind: .rename,
            parentDirectory: targetURL.deletingLastPathComponent(),
            targetURL: targetURL,
            editingNodeID: targetURL,
            draftName: initialName,
            isDirectory: isDirectory
        )
    }

    func withDraftName(_ draftName: String) -> WorkspaceTreeInlineEdit {
        WorkspaceTreeInlineEdit(
            kind: kind,
            parentDirectory: parentDirectory,
            targetURL: targetURL,
            editingNodeID: editingNodeID,
            draftName: draftName,
            isDirectory: isDirectory
        )
    }
}

private enum WorkspaceTreeInlineEditApplier {
    static func apply(inlineEdit: WorkspaceTreeInlineEdit?, to nodes: [FileNode], rootDirectory: URL?) -> [FileNode] {
        guard let inlineEdit else { return nodes }
        if inlineEdit.kind == .rename {
            return nodes
        }

        let placeholderNode = FileNode(
            id: inlineEdit.editingNodeID,
            name: inlineEdit.draftName.isEmpty ? "未命名" : inlineEdit.draftName,
            isDirectory: inlineEdit.isDirectory,
            children: inlineEdit.isDirectory ? [] : nil
        )

        if inlineEdit.parentDirectory == rootDirectory?.standardizedFileURL {
            return [placeholderNode] + nodes
        }

        return injectPlaceholder(placeholderNode, into: nodes, parentDirectory: inlineEdit.parentDirectory)
    }

    private static func injectPlaceholder(_ placeholderNode: FileNode, into nodes: [FileNode], parentDirectory: URL) -> [FileNode] {
        nodes.map { node in
            guard node.isDirectory else { return node }
            if node.id == parentDirectory {
                return FileNode(
                    id: node.id,
                    name: node.name,
                    isDirectory: true,
                    children: [placeholderNode] + (node.children ?? [])
                )
            }

            let updatedChildren = injectPlaceholder(placeholderNode, into: node.children ?? [], parentDirectory: parentDirectory)
            return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren)
        }
    }
}

private struct InlineTreeNameField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> InlineEditorTextField {
        let textField = InlineEditorTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = "输入名称"
        textField.delegate = context.coordinator
        textField.commitHandler = onCommit
        textField.cancelHandler = onCancel
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.identifier = NSUserInterfaceItemIdentifier("workspace.inlineNameField")
        return textField
    }

    func updateNSView(_ nsView: InlineEditorTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.commitHandler = onCommit
        nsView.cancelHandler = onCancel
        context.coordinator.text = $text

        DispatchQueue.main.async {
            nsView.focusIfNeeded()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onCommit: () -> Void
        let onCancel: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }
    }
}

final class InlineEditorTextField: NSTextField {
    enum EndEditingAction: Equatable {
        case commit
        case cancel
    }

    var commitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    private var didAutoFocus = false

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        switch Self.endEditingAction(for: notification.userInfo?["NSTextMovement"] as? Int) {
        case .commit:
            commitHandler?()
        case .cancel:
            cancelHandler?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            cancelHandler?()
        default:
            super.keyDown(with: event)
        }
    }

    func focusIfNeeded() {
        guard !didAutoFocus, let window else { return }
        didAutoFocus = true
        window.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: stringValue.count)
    }

    static func endEditingAction(for movement: Int?) -> EndEditingAction {
        if movement == NSReturnTextMovement {
            return .commit
        }
        return .cancel
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

// MARK: - Preview

#Preview {
    WorkspacePanelView()
        .environment(WorkspaceState())
        .frame(width: 220, height: 500)
}
