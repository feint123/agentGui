import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceTreeViewModel {
    var rootNodes: [FileNode] = []
    var currentDirectory: URL?
    var isLoading = false
    var treeSearchText = ""
    var selectedTreeNodeID: URL?
    var inlineEdit: WorkspaceTreeInlineEdit?
    var pendingDeleteNode: FileNode?
    var errorMessage: String?

    private let actionHandler: WorkspaceTreeActionHandler
    private var refreshCoordinator: WorkspaceTreeRefreshCoordinator

    init(
        refreshCoordinator: WorkspaceTreeRefreshCoordinator? = nil,
        actionHandler: WorkspaceTreeActionHandler = WorkspaceTreeActionHandler()
    ) {
        self.refreshCoordinator = refreshCoordinator ?? WorkspaceTreeRefreshCoordinator()
        self.actionHandler = actionHandler
        configureRefreshCoordinator()
    }

    func loadFromWorkspaceState(
        workspaceState: WorkspaceState,
        globalWorkingDirectory: String,
        refreshGit: @escaping @MainActor (URL) async -> Void
    ) {
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: globalWorkingDirectory)
        guard !dir.isEmpty else {
            rootNodes = []
            currentDirectory = nil
            selectedTreeNodeID = nil
            refreshCoordinator.setDirectory(nil)
            return
        }

        let url = URL(fileURLWithPath: dir).standardizedFileURL
        if url != currentDirectory {
            setDirectory(url, refreshGit: refreshGit)
        }
        if selectedTreeNodeID == nil {
            selectedTreeNodeID = workspaceState.selectedFile?.standardizedFileURL
        }
    }

    func setDirectory(_ url: URL, refreshGit: @escaping @MainActor (URL) async -> Void) {
        currentDirectory = url.standardizedFileURL
        refreshCoordinator.setDirectory(currentDirectory)
        Task { await refreshGit(url.standardizedFileURL) }
    }

    func syncSelection(with selectedFile: URL?) {
        selectedTreeNodeID = selectedFile?.standardizedFileURL
    }

    func nodesForDisplay() -> [FileNode] {
        WorkspaceTreeInlineEditApplier.apply(inlineEdit: inlineEdit, to: rootNodes, rootDirectory: currentDirectory)
    }

    func filteredNodes() -> [FileNode] {
        WorkspaceTreeSnapshotOps.filterNodes(nodesForDisplay(), query: treeSearchText)
    }

    func beginCreate(kind: WorkspaceTreeInlineEdit.Kind, from node: FileNode?) {
        guard let targetDirectory = targetDirectory(for: node) ?? currentDirectory else { return }
        treeSearchText = ""
        inlineEdit = WorkspaceTreeInlineEdit.makeCreate(kind: kind, targetDirectory: targetDirectory)
        selectedTreeNodeID = inlineEdit?.editingNodeID
    }

    func beginRename(for node: FileNode?) {
        guard let node else { return }
        inlineEdit = WorkspaceTreeInlineEdit.makeRename(targetURL: node.id, initialName: node.name, isDirectory: node.isDirectory)
    }

    func commitInlineEdit(workspaceState: WorkspaceState) {
        guard let inlineEdit else { return }
        do {
            switch inlineEdit.kind {
            case .file:
                let createdURL = try WorkspaceFileTreeOperations.createFile(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL.standardizedFileURL
                workspaceState.clearGitDiffSelection()
                workspaceState.selectedFile = createdURL.standardizedFileURL
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([inlineEdit.parentDirectory])
            case .folder:
                let createdURL = try WorkspaceFileTreeOperations.createDirectory(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL.standardizedFileURL
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([inlineEdit.parentDirectory])
            case .rename:
                guard let targetURL = inlineEdit.targetURL else { return }
                let renamedURL = try WorkspaceFileTreeOperations.renameItem(at: targetURL, to: inlineEdit.draftName)
                applySelection(
                    actionHandler.applyingRename(
                        from: targetURL,
                        to: renamedURL,
                        selection: currentSelectionSnapshot(workspaceState: workspaceState)
                    ),
                    workspaceState: workspaceState
                )
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([targetURL.deletingLastPathComponent(), renamedURL.deletingLastPathComponent()])
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelInlineEdit() {
        inlineEdit = nil
    }

    func confirmDelete(_ node: FileNode?) {
        pendingDeleteNode = node
    }

    func deletePendingNode(workspaceState: WorkspaceState) {
        guard let pendingDeleteNode else { return }
        deleteNode(pendingDeleteNode, workspaceState: workspaceState)
    }

    func deleteNode(_ node: FileNode, workspaceState: WorkspaceState) {
        do {
            try WorkspaceFileTreeOperations.deleteItem(at: node.id)
            applySelection(
                actionHandler.applyingDeletion(of: node.id, selection: currentSelectionSnapshot(workspaceState: workspaceState)),
                workspaceState: workspaceState
            )
            pendingDeleteNode = nil
            refreshCoordinator.refreshDirectories([node.id.deletingLastPathComponent()])
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func didTapNode(_ node: FileNode, workspaceState: WorkspaceState) {
        selectedTreeNodeID = node.id.standardizedFileURL
        if !node.isDirectory {
            workspaceState.clearGitDiffSelection()
            workspaceState.selectedFile = node.id.standardizedFileURL
        }
    }

    func selectedNode() -> FileNode? {
        guard let selectedTreeNodeID else { return nil }
        return findNode(in: rootNodes, matching: selectedTreeNodeID)
    }

    func gitChangeMatch(for node: FileNode, snapshot: GitRepositorySnapshot?) -> GitFileChange? {
        guard !node.isDirectory, let snapshot else { return nil }
        let relativePath = relativePath(for: node.id, root: snapshot.repositoryRoot)
        return (snapshot.stagedChanges + snapshot.unstagedChanges + snapshot.untrackedChanges)
            .first { $0.relativePath == relativePath }
    }

    var searchStateText: String {
        if currentDirectory == nil {
            return "none"
        }
        let filteredNodes = WorkspaceTreeSnapshotOps.filterNodes(nodesForDisplay(), query: treeSearchText)
        return filteredNodes.isEmpty ? "empty" : "results"
    }

    private func configureRefreshCoordinator() {
        refreshCoordinator.onNodesChanged = { [weak self] nodes, loading in
            guard let self else { return }
            self.rootNodes = nodes
            self.isLoading = loading
        }
    }

    private func currentSelectionSnapshot(workspaceState: WorkspaceState) -> WorkspaceTreeSelectionSnapshot {
        WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: selectedTreeNodeID,
            selectedFile: workspaceState.selectedFile,
            selectedGitDiffPath: workspaceState.selectedGitDiffPath
        )
    }

    private func applySelection(_ selection: WorkspaceTreeSelectionSnapshot, workspaceState: WorkspaceState) {
        selectedTreeNodeID = selection.selectedTreeNodeID
        workspaceState.selectedFile = selection.selectedFile

        if selection.selectedGitDiffPath == nil {
            workspaceState.clearGitDiffSelection()
        }
    }

    private func targetDirectory(for node: FileNode?) -> URL? {
        guard let node else { return currentDirectory }
        return node.isDirectory ? node.id : node.id.deletingLastPathComponent()
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

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}