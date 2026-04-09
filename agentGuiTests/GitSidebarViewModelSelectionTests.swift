import XCTest
@testable import agentGui

// MARK: - Spy GitServicing

@MainActor
private final class SpyGitService: GitServicing {
    var diffCallCount = 0
    var lastDiffStagedArg: Bool?
    var lastDiffChange: GitFileChange?

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            repositoryRoot: workingDirectory,
            repositoryName: "repo",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [], unstagedChanges: [], untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to: String, repositoryRoot: URL) async throws {}
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        diffCallCount += 1
        lastDiffStagedArg = staged
        lastDiffChange = change
        return "--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n hello"
    }
    func stage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func unstage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func discard(change: GitFileChange, repositoryRoot: URL) async throws {}
    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {}
    func fetch(repositoryRoot: URL) async throws {}
    func pull(repositoryRoot: URL) async throws {}
    func push(repositoryRoot: URL) async throws {}
    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {}
    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] { [] }
    func saveStash(message: String?, repositoryRoot: URL) async throws {}
    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {}
    func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] { [] }
    func stageAll(repositoryRoot: URL) async throws {}
    func unstageAll(repositoryRoot: URL) async throws {}
}

// MARK: - Helpers

@MainActor
private func makeStagedChange(path: String = "Sources/Foo.swift") -> GitFileChange {
    GitFileChange(
        relativePath: path,
        absoluteURL: URL(fileURLWithPath: "/repo/\(path)"),
        status: .modified,
        section: .staged
    )
}

@MainActor
private func makeUnstagedChange(path: String = "Sources/Bar.swift") -> GitFileChange {
    GitFileChange(
        relativePath: path,
        absoluteURL: URL(fileURLWithPath: "/repo/\(path)"),
        status: .modified,
        section: .modified
    )
}

// MARK: - Tests

@MainActor
final class GitSidebarViewModelSelectionTests: XCTestCase {

    func test_initialSelectedChangeID_isNil() {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        XCTAssertNil(vm.selectedChangeID)
    }

    func test_selectChange_stagedFile_callsDiffWithStagedTrue() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        // 预填 snapshot 让 selectDiff 能找到 repositoryRoot
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(spy.diffCallCount, 1)
        XCTAssertEqual(spy.lastDiffStagedArg, true)
    }

    func test_selectChange_unstagedFile_callsDiffWithStagedFalse() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeUnstagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(spy.lastDiffStagedArg, false)
    }

    func test_selectedChangeID_reflectsPanelViewModelAfterSelect() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertEqual(vm.selectedChangeID, change.id)
    }

    func test_selectChange_updatesWorkspaceStateDiffText() async {
        let spy = SpyGitService()
        let panelVM = GitPanelViewModel(gitService: spy)
        panelVM.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        let vm = GitSidebarViewModel(panelViewModel: panelVM)
        let change = makeStagedChange()
        let ws = WorkspaceState()

        await vm.selectChange(change, workspaceState: ws)

        XCTAssertNotNil(ws.selectedGitDiffText)
        XCTAssertEqual(ws.selectedGitDiffTitle, change.relativePath)
    }
}
