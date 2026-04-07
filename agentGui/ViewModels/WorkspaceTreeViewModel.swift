import Foundation
import Observation

enum WorkspaceSearchPresentationState: Equatable {
    case collapsed
    case expanded
}

@Observable
@MainActor
final class WorkspaceTreeViewModel {
    var rootNodes: [FileNode] = []
    var currentDirectory: URL?
    var isLoading = false
    var treeSearchText = ""
    var selectedTreeNodeID: URL?
    var selectedTreeNodeIDs: Set<URL> = []
    var searchPresentationState: WorkspaceSearchPresentationState = .expanded
    var inlineEdit: WorkspaceTreeInlineEdit?
    var pendingDeleteNode: FileNode?
    var pendingDeleteNodeIDs: Set<URL> = []
    var errorMessage: String?

    /// 与 AppSettings.compactFolders 同步，设置时同步到 refreshCoordinator。
    var compactFolders: Bool = true {
        didSet {
            refreshCoordinator.compactFolders = compactFolders
        }
    }

    private let actionHandler: WorkspaceTreeActionHandler
    private var refreshCoordinator: WorkspaceTreeRefreshCoordinator
    private let revealService: WorkspaceRevealServing
    private let dropCoordinator: WorkspaceTreeDropCoordinator
    private weak var activeWorkspaceState: WorkspaceState?
    private var pendingSelectedFileSyncBypass: URL??

    init(
        refreshCoordinator: WorkspaceTreeRefreshCoordinator? = nil,
        actionHandler: WorkspaceTreeActionHandler = WorkspaceTreeActionHandler(),
        revealService: WorkspaceRevealServing = WorkspaceRevealService(),
        dropCoordinator: WorkspaceTreeDropCoordinator = WorkspaceTreeDropCoordinator()
    ) {
        self.refreshCoordinator = refreshCoordinator ?? WorkspaceTreeRefreshCoordinator()
        self.actionHandler = actionHandler
        self.revealService = revealService
        self.dropCoordinator = dropCoordinator
        configureRefreshCoordinator()
    }

    var primarySelectionID: URL? {
        selectedTreeNodeID
    }

    var hasSelection: Bool {
        selectedTreeNodeID != nil || !selectedTreeNodeIDs.isEmpty
    }

    var hasMultipleSelection: Bool {
        selectedTreeNodeIDs.count > 1
    }

    func loadFromWorkspaceState(
        workspaceState: WorkspaceState,
        globalWorkingDirectory: String,
        refreshGit: @escaping @MainActor (URL) async -> Void
    ) {
        activeWorkspaceState = workspaceState
        let dir = workspaceState.effectiveWorkingDirectory(globalDefault: globalWorkingDirectory)
        guard !dir.isEmpty else {
            rootNodes = []
            currentDirectory = nil
            selectedTreeNodeID = nil
            selectedTreeNodeIDs = []
            refreshCoordinator.setDirectory(nil)
            return
        }

        let url = URL(fileURLWithPath: dir).standardizedFileURL
        if url != currentDirectory {
            setDirectory(url, refreshGit: refreshGit)
        }
        if selectedTreeNodeID == nil {
            syncSelection(with: workspaceState.selectedFile)
        }
    }

    func setDirectory(_ url: URL, refreshGit: @escaping @MainActor (URL) async -> Void) {
        currentDirectory = url.standardizedFileURL
        refreshCoordinator.setDirectory(currentDirectory)
        Task { await refreshGit(url.standardizedFileURL) }
    }

    func demandLoadDirectory(_ url: URL) {
        refreshCoordinator.demandLoad(directoryID: url)
    }

    func syncSelection(with selectedFile: URL?) {
        let normalizedSelectedFile = selectedFile?.standardizedFileURL
        if let pendingSelectedFileSyncBypass {
            self.pendingSelectedFileSyncBypass = nil
            if pendingSelectedFileSyncBypass == normalizedSelectedFile {
                return
            }
        }

        selectedTreeNodeID = normalizedSelectedFile
        if let selectedTreeNodeID {
            selectedTreeNodeIDs = [selectedTreeNodeID]
        } else {
            selectedTreeNodeIDs = []
        }
    }

    func expandSearch() {
        searchPresentationState = .expanded
    }

    func collapseSearch() {
        treeSearchText = ""
        searchPresentationState = .collapsed
    }

    func openSingleSearchResultIfPossible(workspaceState: WorkspaceState) {
        let fileNodes = filteredNodes().flatMap(flattenedFileNodes).filter { !$0.isDirectory }
        guard fileNodes.count == 1, let match = fileNodes.first else { return }
        selectNode(match, additive: false, workspaceState: workspaceState)
    }

    func selectNode(_ node: FileNode, additive: Bool, workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState
        let standardizedID = node.id.standardizedFileURL
        let wasSelected = selectedTreeNodeIDs.contains(standardizedID)

        if additive {
            if wasSelected {
                selectedTreeNodeIDs.remove(standardizedID)
                if selectedTreeNodeID == standardizedID {
                    selectedTreeNodeID = selectedTreeNodeIDs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.last
                }
            } else {
                selectedTreeNodeIDs.insert(standardizedID)
                selectedTreeNodeID = standardizedID
            }
        } else {
            selectedTreeNodeIDs = [standardizedID]
            selectedTreeNodeID = standardizedID
        }

        guard !node.isDirectory else { return }

        if additive, wasSelected {
            if let selectedTreeNodeID,
               let promotedNode = findNode(in: rootNodes, matching: selectedTreeNodeID),
               !promotedNode.isDirectory {
                updateWorkspaceSelectedFile(selectedTreeNodeID, workspaceState: workspaceState)
            } else if workspaceState.selectedFile?.standardizedFileURL == standardizedID {
                updateWorkspaceSelectedFile(nil, workspaceState: workspaceState)
            }
            return
        }

        guard selectedTreeNodeID == standardizedID else { return }
        updateWorkspaceSelectedFile(standardizedID, workspaceState: workspaceState)
    }

    func applyOutlineSelection(ids: Set<URL>, primaryID: URL?, workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState

        let normalizedSelection = normalizedSelectionIDs(ids, primaryID: primaryID)
        let resolvedPrimary = resolvedPrimarySelection(in: normalizedSelection, preferredPrimary: primaryID)

        selectedTreeNodeIDs = normalizedSelection
        selectedTreeNodeID = resolvedPrimary

        guard let resolvedPrimary,
              let node = findNode(in: rootNodes, matching: resolvedPrimary),
              !node.isDirectory else {
            return
        }

                updateWorkspaceSelectedFile(resolvedPrimary, workspaceState: workspaceState)
    }

    func applyListSelectionChange(_ ids: Set<URL>, workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState

        let previousSelection = normalizedSelectionIDs(selectedTreeNodeIDs, primaryID: selectedTreeNodeID)
        let normalizedSelection = normalizedSelectionIDs(ids, primaryID: nil)
        let addedIDs = normalizedSelection.subtracting(previousSelection)
        let removedIDs = previousSelection.subtracting(normalizedSelection)
        let promotedPrimary = addedIDs.sorted(by: selectionSort).last
        let resolvedPrimary: URL?

        if let promotedPrimary {
            resolvedPrimary = promotedPrimary
        } else if let currentPrimary = selectedTreeNodeID?.standardizedFileURL,
                  normalizedSelection.contains(currentPrimary) {
            resolvedPrimary = currentPrimary
        } else {
            resolvedPrimary = normalizedSelection.sorted(by: selectionSort).last
        }

        selectedTreeNodeIDs = normalizedSelection
        selectedTreeNodeID = resolvedPrimary

        if let promotedPrimary,
           let node = findNode(in: rootNodes, matching: promotedPrimary),
           !node.isDirectory {
            updateWorkspaceSelectedFile(promotedPrimary, workspaceState: workspaceState)
            return
        }

        if let selectedFile = workspaceState.selectedFile?.standardizedFileURL,
           removedIDs.contains(selectedFile) {
            updateWorkspaceSelectedFile(nil, workspaceState: workspaceState)
        }
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
        selectedTreeNodeIDs = inlineEdit.map { [$0.editingNodeID.standardizedFileURL] } ?? []
    }

    func beginRename(for node: FileNode?) {
        guard !hasMultipleSelection else { return }
        guard let node else { return }
        selectedTreeNodeID = node.id.standardizedFileURL
        selectedTreeNodeIDs = [node.id.standardizedFileURL]
        inlineEdit = WorkspaceTreeInlineEdit.makeRename(targetURL: node.id, initialName: node.name, isDirectory: node.isDirectory)
    }

    func commitInlineEdit(workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState
        guard let inlineEdit else { return }
        do {
            switch inlineEdit.kind {
            case .file:
                let createdURL = try WorkspaceFileTreeOperations.createFile(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL.standardizedFileURL
                selectedTreeNodeIDs = [createdURL.standardizedFileURL]
                updateWorkspaceSelectedFile(createdURL.standardizedFileURL, workspaceState: workspaceState)
                self.inlineEdit = nil
                refreshCoordinator.refreshDirectories([inlineEdit.parentDirectory])
            case .folder:
                let createdURL = try WorkspaceFileTreeOperations.createDirectory(named: inlineEdit.draftName, in: inlineEdit.parentDirectory)
                selectedTreeNodeID = createdURL.standardizedFileURL
                selectedTreeNodeIDs = [createdURL.standardizedFileURL]
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
        if let node {
            pendingDeleteNode = node
            pendingDeleteNodeIDs = [node.id.standardizedFileURL]
            return
        }

        let nodes = selectedNodes()
        guard !nodes.isEmpty else { return }

        pendingDeleteNode = selectedNode() ?? nodes.first
        pendingDeleteNodeIDs = Set(collapsedURLs(nodes.map(\.id)))
    }

    func deletePendingNode(workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState
        let urlsToDelete = collapsedURLs(Array(pendingDeleteNodeIDs))
        guard !urlsToDelete.isEmpty else { return }

        do {
            var updatedSelection = currentSelectionSnapshot(workspaceState: workspaceState)
            var parentDirectories = Set<URL>()

            for url in urlsToDelete {
                try WorkspaceFileTreeOperations.deleteItem(at: url)
                updatedSelection = actionHandler.applyingDeletion(of: url, selection: updatedSelection)
                parentDirectories.insert(url.deletingLastPathComponent().standardizedFileURL)
            }

            applySelection(updatedSelection, workspaceState: workspaceState)
            clearPendingDelete()
            refreshCoordinator.refreshDirectories(Array(parentDirectories))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteNode(_ node: FileNode, workspaceState: WorkspaceState) {
        activeWorkspaceState = workspaceState
        do {
            try WorkspaceFileTreeOperations.deleteItem(at: node.id)
            applySelection(
                actionHandler.applyingDeletion(of: node.id, selection: currentSelectionSnapshot(workspaceState: workspaceState)),
                workspaceState: workspaceState
            )
            clearPendingDelete()
            refreshCoordinator.refreshDirectories([node.id.deletingLastPathComponent()])
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    func moveSelection(to destination: FileNode?, workspaceState: WorkspaceState) -> Bool {
        activeWorkspaceState = workspaceState
        let selectionIDs = selectedTreeNodeIDs.isEmpty
            ? Set(selectedTreeNodeID.map { [$0] } ?? [])
            : selectedTreeNodeIDs

        guard let plan = dropCoordinator.proposal(
            for: selectionIDs,
            destination: destination,
            rootDirectory: currentDirectory
        ) else { return false }

        do {
            let movedURLs = try WorkspaceFileTreeOperations.moveItems(at: plan.draggedURLs, to: plan.destinationDirectory)
            applySelection(
                actionHandler.applyingMove(
                    from: plan.draggedURLs,
                    to: movedURLs,
                    selection: currentSelectionSnapshot(workspaceState: workspaceState)
                ),
                workspaceState: workspaceState
            )
            let refreshTargets = Set(plan.draggedURLs.map { $0.deletingLastPathComponent().standardizedFileURL })
                .union([plan.destinationDirectory.standardizedFileURL])
            refreshCoordinator.refreshDirectories(Array(refreshTargets))
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func beginDragging(_ node: FileNode, workspaceState: WorkspaceState) {
        let nodeID = node.id.standardizedFileURL
        if !selectedTreeNodeIDs.contains(nodeID) {
            selectNode(node, additive: false, workspaceState: workspaceState)
        }
    }

    func canMoveSelection(to destination: FileNode?) -> Bool {
        let selectionIDs = selectedTreeNodeIDs.isEmpty
            ? Set(selectedTreeNodeID.map { [$0] } ?? [])
            : selectedTreeNodeIDs

        return dropCoordinator.proposal(
            for: selectionIDs,
            destination: destination,
            rootDirectory: currentDirectory
        ) != nil
    }

    func handleDrop(on destination: FileNode?, workspaceState: WorkspaceState) -> Bool {
        moveSelection(to: destination, workspaceState: workspaceState)
    }

    func beginCreateFromSelection(kind: WorkspaceTreeInlineEdit.Kind) {
        beginCreate(kind: kind, from: selectedNode())
    }

    func beginRenameFromSelection() {
        beginRename(for: selectedNode())
    }

    func confirmDeleteSelection() {
        confirmDelete(nil)
    }

    func didTapNode(_ node: FileNode, workspaceState: WorkspaceState) {
        selectNode(node, additive: false, workspaceState: workspaceState)
    }

    func selectedNode() -> FileNode? {
        guard let selectedTreeNodeID else { return nil }
        return findNode(in: rootNodes, matching: selectedTreeNodeID)
    }

    func selectedNodes() -> [FileNode] {
        let selectionIDs = selectedTreeNodeIDs.isEmpty
            ? (selectedTreeNodeID.map { [$0] } ?? [])
            : Array(selectedTreeNodeIDs)

        return selectionIDs
            .compactMap { findNode(in: rootNodes, matching: $0) }
            .sorted { $0.id.path.localizedStandardCompare($1.id.path) == .orderedAscending }
    }

    func revealSelectionInFinder() {
        revealService.revealInFinder(selectedNodes().map(\.id))
    }

    func relativePathsForSelection(root: URL? = nil) -> [String] {
        let baseURL = (root ?? currentDirectory)?.standardizedFileURL
        return selectedNodes().map { node in
            guard let baseURL else { return node.name }
            return relativePath(for: node.id, root: baseURL)
        }
    }

    var pendingDeleteSelectionCount: Int {
        pendingDeleteNodeIDs.count
    }

    var selectionSummaryText: String? {
        let nodes = selectedNodes()
        switch nodes.count {
        case 0:
            return nil
        case 1:
            return "已选：\(nodes[0].name)"
        default:
            return "已选 \(nodes.count) 项"
        }
    }

    func clearPendingDelete() {
        pendingDeleteNode = nil
        pendingDeleteNodeIDs = []
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
            self.reconcileSelectionAfterRefresh(nodes: nodes)
            self.rootNodes = nodes
            self.isLoading = loading
        }
    }

    private func reconcileSelectionAfterRefresh(nodes: [FileNode]) {
        let availableIDs = Set(flattenedNodes(in: nodes).map { $0.id.standardizedFileURL })
        let prunedSelections = Set(selectedTreeNodeIDs.filter { availableIDs.contains($0.standardizedFileURL) })
        let prunedPrimary: URL?
        if let selectedTreeNodeID {
            let standardizedPrimary = selectedTreeNodeID.standardizedFileURL
            prunedPrimary = availableIDs.contains(standardizedPrimary) ? standardizedPrimary : nil
        } else {
            prunedPrimary = nil
        }

        selectedTreeNodeIDs = prunedSelections
        selectedTreeNodeID = prunedPrimary ?? prunedSelections.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }.last

        guard let activeWorkspaceState else { return }

        if let selectedFile = activeWorkspaceState.selectedFile?.standardizedFileURL,
           !availableIDs.contains(selectedFile) {
            activeWorkspaceState.showFileDetail(nil)
        }

        if let selectedGitDiffPath = activeWorkspaceState.selectedGitDiffPath?.standardizedFileURL,
           !availableIDs.contains(selectedGitDiffPath) {
            activeWorkspaceState.clearGitDiffSelection()
        }
    }

    private func currentSelectionSnapshot(workspaceState: WorkspaceState) -> WorkspaceTreeSelectionSnapshot {
        WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: selectedTreeNodeID,
            selectedTreeNodeIDs: selectedTreeNodeIDs,
            selectedFile: workspaceState.selectedFile,
            selectedGitDiffPath: workspaceState.selectedGitDiffPath
        )
    }

    private func applySelection(_ selection: WorkspaceTreeSelectionSnapshot, workspaceState: WorkspaceState) {
        selectedTreeNodeID = selection.primarySelectionID
        selectedTreeNodeIDs = selection.selectedTreeNodeIDs
        if workspaceState.selectedFile?.standardizedFileURL != selection.selectedFile?.standardizedFileURL {
            pendingSelectedFileSyncBypass = selection.selectedFile?.standardizedFileURL
        }
        if let selectedFile = selection.selectedFile {
            workspaceState.showFileDetail(selectedFile)
        } else if case .file = workspaceState.detailSelection {
            workspaceState.showFileDetail(nil)
        } else {
            workspaceState.selectedFile = nil
        }

        if selection.selectedGitDiffPath == nil {
            workspaceState.clearGitDiffSelection()
        } else {
            workspaceState.selectedGitDiffPath = selection.selectedGitDiffPath
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

    private func normalizedSelectionIDs(_ ids: Set<URL>, primaryID: URL?) -> Set<URL> {
        let normalizedIDs = Set(ids.map(\.standardizedFileURL))
        guard let primaryID = primaryID?.standardizedFileURL else {
            return normalizedIDs
        }
        return normalizedIDs.union([primaryID])
    }

    private func resolvedPrimarySelection(in ids: Set<URL>, preferredPrimary: URL?) -> URL? {
        let normalizedPreferredPrimary = preferredPrimary?.standardizedFileURL
        if let normalizedPreferredPrimary,
           ids.contains(normalizedPreferredPrimary) {
            return normalizedPreferredPrimary
        }
        return ids.sorted(by: selectionSort).last
    }

    private func selectionSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func flattenedFileNodes(in node: FileNode) -> [FileNode] {
        if node.isDirectory {
            return (node.children ?? []).flatMap(flattenedFileNodes)
        }
        return [node]
    }

    private func flattenedNodes(in nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node in
            if node.isDirectory {
                return [node] + flattenedNodes(in: node.children ?? [])
            }
            return [node]
        }
    }

    private func collapsedURLs(_ urls: [URL]) -> [URL] {
        let normalized = Array(Set(urls.map(\.standardizedFileURL)))
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        var collapsed: [URL] = []
        for candidate in normalized {
            let coveredByAncestor = collapsed.contains { existing in
                candidate.path == existing.path || candidate.path.hasPrefix(existing.path + "/")
            }
            if !coveredByAncestor {
                collapsed.append(candidate)
            }
        }
        return collapsed
    }

    private func updateWorkspaceSelectedFile(_ selectedFile: URL?, workspaceState: WorkspaceState) {
        let normalizedSelectedFile = selectedFile?.standardizedFileURL
        if workspaceState.selectedFile?.standardizedFileURL != normalizedSelectedFile {
            pendingSelectedFileSyncBypass = normalizedSelectedFile
        }
        workspaceState.showFileDetail(normalizedSelectedFile)
    }
}