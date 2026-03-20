import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeViewModelTests {

    @Test func commandToggleKeepsPrimarySelectionAndAddsSecondarySelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]

        viewModel.selectNode(readme, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(notes, additive: true, workspaceState: workspaceState)

        #expect(viewModel.primarySelectionID == notes.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL, notes.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == notes.id.standardizedFileURL)
    }

    @Test func outlineSelectionSyncUpdatesPrimarySelectionAndOpenFile() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]

        viewModel.applyOutlineSelection(
            ids: [readme.id.standardizedFileURL, notes.id.standardizedFileURL],
            primaryID: readme.id.standardizedFileURL,
            workspaceState: workspaceState
        )

        #expect(viewModel.primarySelectionID == readme.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL, notes.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == readme.id.standardizedFileURL)
    }

    @Test func internalSelectedFileSyncDoesNotCollapseMultiSelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]

        viewModel.applyOutlineSelection(
            ids: [readme.id.standardizedFileURL, notes.id.standardizedFileURL],
            primaryID: notes.id.standardizedFileURL,
            workspaceState: workspaceState
        )
        viewModel.syncSelection(with: workspaceState.selectedFile)

        #expect(viewModel.primarySelectionID == notes.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL, notes.id.standardizedFileURL])
    }

    @Test func externalSelectedFileSyncCollapsesSelectionToRequestedFile() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )
        let guide = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Guide.md"),
            name: "Guide.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes, guide]

        viewModel.applyOutlineSelection(
            ids: [readme.id.standardizedFileURL, notes.id.standardizedFileURL],
            primaryID: notes.id.standardizedFileURL,
            workspaceState: workspaceState
        )
        viewModel.syncSelection(with: guide.id.standardizedFileURL)

        #expect(viewModel.primarySelectionID == guide.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [guide.id.standardizedFileURL])
    }

    @Test func deselectingPrimaryFilePromotesRemainingFileIntoWorkspaceSelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]

        viewModel.selectNode(readme, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(notes, additive: true, workspaceState: workspaceState)
        viewModel.selectNode(notes, additive: true, workspaceState: workspaceState)

        #expect(viewModel.primarySelectionID == readme.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == readme.id.standardizedFileURL)
    }

    @Test func outlineSelectionSyncKeepsOpenFileWhenPrimarySelectionBecomesDirectory() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let docs = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Docs"),
            name: "Docs",
            isDirectory: true,
            children: []
        )
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [docs, readme]
        workspaceState.selectedFile = readme.id.standardizedFileURL

        viewModel.applyOutlineSelection(
            ids: [docs.id.standardizedFileURL],
            primaryID: docs.id.standardizedFileURL,
            workspaceState: workspaceState
        )

        #expect(viewModel.primarySelectionID == docs.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [docs.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == readme.id.standardizedFileURL)
    }

    @Test func listSelectionChangePromotesAddedItemToPrimarySelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]
        viewModel.selectNode(readme, additive: false, workspaceState: workspaceState)

        viewModel.applyListSelectionChange(
            [readme.id.standardizedFileURL, notes.id.standardizedFileURL],
            workspaceState: workspaceState
        )

        #expect(viewModel.primarySelectionID == notes.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL, notes.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == notes.id.standardizedFileURL)
    }

    @Test func listSelectionChangeRemovingPrimaryClearsOpenFileAndKeepsRemainingSelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let readme = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [readme, notes]
        viewModel.selectNode(readme, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(notes, additive: true, workspaceState: workspaceState)

        viewModel.applyListSelectionChange(
            [readme.id.standardizedFileURL],
            workspaceState: workspaceState
        )

        #expect(viewModel.primarySelectionID == readme.id.standardizedFileURL)
        #expect(viewModel.selectedTreeNodeIDs == [readme.id.standardizedFileURL])
        #expect(workspaceState.selectedFile == nil)
    }

    @Test func escapeClearsSearchQueryAndCollapsesSearchPresentation() {
        let viewModel = WorkspaceTreeViewModel()

        viewModel.expandSearch()
        viewModel.treeSearchText = "note"
        viewModel.collapseSearch()

        #expect(viewModel.treeSearchText.isEmpty)
        #expect(viewModel.searchPresentationState == .collapsed)
    }

    @Test func returnOpensSingleFilteredFileResult() {
        let workspaceState = WorkspaceState()
        let viewModel = WorkspaceTreeViewModel()
        let notes = FileNode(
            id: URL(fileURLWithPath: "/tmp/ws/Notes.md"),
            name: "Notes.md",
            isDirectory: false,
            children: nil
        )

        viewModel.rootNodes = [notes]
        viewModel.expandSearch()
        viewModel.treeSearchText = "notes"

        viewModel.openSingleSearchResultIfPossible(workspaceState: workspaceState)

        #expect(viewModel.primarySelectionID == notes.id.standardizedFileURL)
        #expect(workspaceState.selectedFile == notes.id.standardizedFileURL)
    }

    @Test func deletePendingSelectionRemovesAllSelectedItems() throws {
        let rootURL = try makeWorkspaceTreeViewModelTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let docsURL = try WorkspaceFileTreeOperations.createDirectory(named: "Docs", in: rootURL)
        let readmeURL = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: docsURL)
        let notesURL = try WorkspaceFileTreeOperations.createFile(named: "Notes.md", in: docsURL)

        let refreshCoordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },
            buildNodes: { _ in [] },
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )
        let viewModel = WorkspaceTreeViewModel(refreshCoordinator: refreshCoordinator)
        let workspaceState = WorkspaceState()
        let readmeNode = FileNode(id: readmeURL, name: "README.md", isDirectory: false, children: nil)
        let notesNode = FileNode(id: notesURL, name: "Notes.md", isDirectory: false, children: nil)

        viewModel.currentDirectory = rootURL
        viewModel.rootNodes = [
            FileNode(id: docsURL, name: "Docs", isDirectory: true, children: [readmeNode, notesNode])
        ]

        viewModel.selectNode(readmeNode, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(notesNode, additive: true, workspaceState: workspaceState)
        viewModel.confirmDelete(nil)
        viewModel.deletePendingNode(workspaceState: workspaceState)

        #expect(viewModel.selectedTreeNodeIDs.isEmpty)
        #expect(viewModel.primarySelectionID == nil)
        #expect(viewModel.pendingDeleteSelectionCount == 0)
        #expect(workspaceState.selectedFile == nil)
        #expect(!FileManager.default.fileExists(atPath: readmeURL.path))
        #expect(!FileManager.default.fileExists(atPath: notesURL.path))
    }

    @Test func moveSelectionMovesFilesAndRemapsSelection() throws {
        let rootURL = try makeWorkspaceTreeViewModelTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let docsURL = try WorkspaceFileTreeOperations.createDirectory(named: "Docs", in: rootURL)
        let archiveURL = try WorkspaceFileTreeOperations.createDirectory(named: "Archive", in: rootURL)
        let readmeURL = try WorkspaceFileTreeOperations.createFile(named: "README.md", in: docsURL)
        let notesURL = try WorkspaceFileTreeOperations.createFile(named: "Notes.md", in: docsURL)

        let refreshCoordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },
            buildNodes: { _ in [] },
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )
        let viewModel = WorkspaceTreeViewModel(refreshCoordinator: refreshCoordinator)
        let workspaceState = WorkspaceState()
        let readmeNode = FileNode(id: readmeURL, name: "README.md", isDirectory: false, children: nil)
        let notesNode = FileNode(id: notesURL, name: "Notes.md", isDirectory: false, children: nil)
        let archiveNode = FileNode(id: archiveURL, name: "Archive", isDirectory: true, children: [])

        viewModel.currentDirectory = rootURL
        viewModel.rootNodes = [
            FileNode(id: docsURL, name: "Docs", isDirectory: true, children: [readmeNode, notesNode]),
            archiveNode
        ]

        viewModel.selectNode(readmeNode, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(notesNode, additive: true, workspaceState: workspaceState)
        workspaceState.selectedGitDiffPath = notesURL.standardizedFileURL
        viewModel.moveSelection(to: archiveNode, workspaceState: workspaceState)

        #expect(viewModel.selectedTreeNodeIDs == [
            archiveURL.appending(path: "README.md").standardizedFileURL,
            archiveURL.appending(path: "Notes.md").standardizedFileURL
        ])
        #expect(viewModel.primarySelectionID == archiveURL.appending(path: "Notes.md").standardizedFileURL)
        #expect(workspaceState.selectedFile == archiveURL.appending(path: "Notes.md").standardizedFileURL)
        #expect(workspaceState.selectedGitDiffPath == archiveURL.appending(path: "Notes.md").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: archiveURL.appending(path: "README.md").path))
        #expect(FileManager.default.fileExists(atPath: archiveURL.appending(path: "Notes.md").path))
    }

    @Test func refreshPrunesSelectionsForDeletedNodes() throws {
        let refreshCoordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: .init { _, _ in nil },
            buildNodes: { _ in [] },
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )
        let viewModel = WorkspaceTreeViewModel(refreshCoordinator: refreshCoordinator)
        let workspaceState = WorkspaceState()
        let docsURL = URL(fileURLWithPath: "/tmp/ws/Docs")
        let readmeNode = FileNode(
            id: docsURL.appending(path: "README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )

        viewModel.currentDirectory = URL(fileURLWithPath: "/tmp/ws")
        viewModel.rootNodes = [
            FileNode(id: docsURL, name: "Docs", isDirectory: true, children: [readmeNode])
        ]

        viewModel.selectNode(readmeNode, additive: false, workspaceState: workspaceState)
        workspaceState.selectedGitDiffPath = readmeNode.id.standardizedFileURL

        refreshCoordinator.onNodesChanged?([
            FileNode(id: docsURL, name: "Docs", isDirectory: true, children: [])
        ], false)

        #expect(viewModel.selectedTreeNodeIDs.isEmpty)
        #expect(viewModel.primarySelectionID == nil)
        #expect(workspaceState.selectedFile == nil)
        #expect(workspaceState.selectedGitDiffPath == nil)
    }

    @Test func relativePathsForSelectionStayStableForMixedDirectoryAndFileSelection() {
        let viewModel = WorkspaceTreeViewModel()
        let workspaceState = WorkspaceState()
        let rootURL = URL(fileURLWithPath: "/tmp/ws")
        let docsNode = FileNode(
            id: rootURL.appending(path: "Docs"),
            name: "Docs",
            isDirectory: true,
            children: []
        )
        let readmeNode = FileNode(
            id: rootURL.appending(path: "README.md"),
            name: "README.md",
            isDirectory: false,
            children: nil
        )

        viewModel.currentDirectory = rootURL
        viewModel.rootNodes = [docsNode, readmeNode]

        viewModel.selectNode(readmeNode, additive: false, workspaceState: workspaceState)
        viewModel.selectNode(docsNode, additive: true, workspaceState: workspaceState)

        #expect(viewModel.relativePathsForSelection() == ["Docs", "README.md"])
    }
}

private func makeWorkspaceTreeViewModelTemporaryDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
    let directoryURL = baseURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}