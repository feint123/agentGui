import Foundation
import Testing
@testable import agentGui

@MainActor
struct GitPanelViewModelTests {

    @Test func refreshStoresSnapshotAndClearsLoadError() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main")
        let viewModel = GitPanelViewModel(gitService: service)

        await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))

        #expect(viewModel.snapshot?.branchName == "main")
        #expect(viewModel.loadError == nil)
        #expect(service.refreshInputs == [URL(fileURLWithPath: "/tmp/repo")])
    }

    @Test func refreshTreatsNonRepositoryAsEmptyState() async throws {
        let service = FakeGitService()
        service.snapshotError = .notAGitRepository
        let viewModel = GitPanelViewModel(gitService: service)

        await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/no-git"))

        #expect(viewModel.snapshot == nil)
        #expect(viewModel.loadError == nil)
    }

    @Test func selectDiffWritesWorkspaceDiffState() async throws {
        let service = FakeGitService()
        service.diffText = "diff --git a/file b/file"
        let viewModel = GitPanelViewModel(gitService: service)
        let workspaceState = WorkspaceState()
        let change = GitRepositorySnapshot.fixture().unstagedChanges[0]

        await viewModel.selectDiff(for: change, staged: false, workspaceState: workspaceState)

        #expect(viewModel.selectedChange == change)
        #expect(viewModel.selectedDiffText == "diff --git a/file b/file")
        #expect(workspaceState.selectedGitDiffText == "diff --git a/file b/file")
        #expect(workspaceState.selectedGitDiffPath == change.absoluteURL)
        #expect(workspaceState.detailSelection == .gitDiff(title: change.relativePath, diffText: "diff --git a/file b/file"))
    }

    @Test func selectDiffKeepsChinesePathSelectionState() async throws {
        let service = FakeGitService()
        service.diffText = "diff --git a/文档/需求说明.md b/文档/需求说明.md"
        let viewModel = GitPanelViewModel(gitService: service)
        let workspaceState = WorkspaceState()
        let root = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "文档/需求说明.md",
            absoluteURL: root.appending(path: "文档/需求说明.md"),
            status: .modified,
            section: .modified
        )

        await viewModel.selectDiff(for: change, staged: false, workspaceState: workspaceState)

        #expect(viewModel.selectedChange?.relativePath == "文档/需求说明.md")
        #expect(viewModel.selectedDiffSection == .modified)
        #expect(workspaceState.selectedGitDiffTitle == "文档/需求说明.md")
        #expect(workspaceState.detailSelection == .gitDiff(title: "文档/需求说明.md", diffText: "diff --git a/文档/需求说明.md b/文档/需求说明.md"))
    }

    @Test func refreshPreservesSelectedChangeWhenStillPresent() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main")
        let viewModel = GitPanelViewModel(gitService: service)
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")

        let existingChange = GitRepositorySnapshot.fixture().unstagedChanges[0]
        viewModel.selectedChange = existingChange
        viewModel.selectedDiffSection = .modified
        workspaceState.selectedGitDiffPath = existingChange.absoluteURL
        workspaceState.selectedGitDiffTitle = existingChange.relativePath
        workspaceState.selectedGitDiffText = "diff --git a/file b/file"

        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        #expect(viewModel.selectedChange?.relativePath == existingChange.relativePath)
        #expect(workspaceState.selectedGitDiffPath == existingChange.absoluteURL)
    }

    @Test func refreshClearsSelectionWhenChangeDisappears() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main", unstagedChanges: [])
        let viewModel = GitPanelViewModel(gitService: service)
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")

        let removedChange = GitRepositorySnapshot.fixture().unstagedChanges[0]
        viewModel.selectedChange = removedChange
        viewModel.selectedDiffSection = .modified
        viewModel.selectedDiffText = "diff --git a/file b/file"
        workspaceState.selectedGitDiffPath = removedChange.absoluteURL
        workspaceState.selectedGitDiffTitle = removedChange.relativePath
        workspaceState.selectedGitDiffText = "diff --git a/file b/file"

        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        #expect(viewModel.selectedChange == nil)
        #expect(viewModel.selectedDiffText == nil)
        #expect(workspaceState.selectedGitDiffPath == nil)
        #expect(workspaceState.selectedGitDiffTitle == nil)
    }

    @Test func refreshAlsoLoadsAvailableBranches() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main")
        service.branches = [
            .init(name: "main", isCurrent: true),
            .init(name: "feature/sidebar", isCurrent: false)
        ]
        let viewModel = GitPanelViewModel(gitService: service)

        await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))

        #expect(viewModel.availableBranches.map(\.name) == ["main", "feature/sidebar"])
        #expect(viewModel.availableBranches.first?.isCurrent == true)
    }

    @Test func switchBranchRefreshesSnapshotAndBranches() async throws {
        let service = FakeGitService()
        let viewModel = GitPanelViewModel(gitService: service)
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")

        service.snapshot = .fixture(branchName: "main")
        service.branches = [
            .init(name: "main", isCurrent: true),
            .init(name: "feature/sidebar", isCurrent: false)
        ]

        await viewModel.refresh(for: workingDirectory)

        service.snapshot = .fixture(branchName: "feature/sidebar")
        service.branches = [
            .init(name: "main", isCurrent: false),
            .init(name: "feature/sidebar", isCurrent: true)
        ]

        await viewModel.switchBranch(to: "feature/sidebar")

        #expect(service.switchedBranches == ["feature/sidebar"])
        #expect(viewModel.snapshot?.branchName == "feature/sidebar")
        #expect(viewModel.availableBranches.first(where: { $0.name == "feature/sidebar" })?.isCurrent == true)
    }

    @Test func switchBranchStoresUserFacingErrorOnFailure() async throws {
        let service = FakeGitService()
        let viewModel = GitPanelViewModel(gitService: service)

        service.snapshot = .fixture(branchName: "main")
        service.branches = [
            .init(name: "main", isCurrent: true),
            .init(name: "feature/sidebar", isCurrent: false)
        ]
        service.switchBranchError = .commandFailed("fatal: invalid reference: missing-branch")

        await viewModel.refresh(for: URL(fileURLWithPath: "/tmp/repo"))
        await viewModel.switchBranch(to: "missing-branch")

        #expect(viewModel.branchActionError == "fatal: invalid reference: missing-branch")
    }

    @Test func stageRefreshesSnapshotAfterMutation() async throws {
        let service = FakeGitService()
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        let initialSnapshot = GitRepositorySnapshot.fixture()
        let stagedSnapshot = GitRepositorySnapshot.fixture(
            stagedChanges: [initialSnapshot.unstagedChanges[0]],
            unstagedChanges: []
        )
        service.snapshot = initialSnapshot

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        service.snapshot = stagedSnapshot
        await viewModel.stage(change: initialSnapshot.unstagedChanges[0], workspaceState: workspaceState)

        #expect(service.stagedChanges == [initialSnapshot.unstagedChanges[0].relativePath])
        #expect(viewModel.snapshot?.stagedChanges.contains(where: { $0.relativePath == initialSnapshot.unstagedChanges[0].relativePath }) == true)
        #expect(service.refreshInputs.count == 2)
    }

    @Test func unstageRefreshesSnapshotAfterMutation() async throws {
        let service = FakeGitService()
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        let initialSnapshot = GitRepositorySnapshot.fixture()
        let unstagedSnapshot = GitRepositorySnapshot.fixture(
            stagedChanges: [],
            unstagedChanges: [initialSnapshot.stagedChanges[0]]
        )
        service.snapshot = initialSnapshot

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        service.snapshot = unstagedSnapshot
        await viewModel.unstage(change: initialSnapshot.stagedChanges[0], workspaceState: workspaceState)

        #expect(service.unstagedChanges == [initialSnapshot.stagedChanges[0].relativePath])
        #expect(viewModel.snapshot?.unstagedChanges.contains(where: { $0.relativePath == initialSnapshot.stagedChanges[0].relativePath }) == true)
    }

    @Test func discardRefreshesSnapshotAfterMutation() async throws {
        let service = FakeGitService()
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        let initialSnapshot = GitRepositorySnapshot.fixture()
        let cleanSnapshot = GitRepositorySnapshot.fixture(stagedChanges: [], unstagedChanges: [], untrackedChanges: [])
        service.snapshot = initialSnapshot

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        service.snapshot = cleanSnapshot
        await viewModel.discard(change: initialSnapshot.unstagedChanges[0], workspaceState: workspaceState)

        #expect(service.discardedChanges == [initialSnapshot.unstagedChanges[0].relativePath])
        #expect(viewModel.snapshot?.unstagedChanges.isEmpty == true)
    }

    @Test func commitRefreshesSnapshotAndClearsBranchActionError() async throws {
        let service = FakeGitService()
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        service.snapshot = .fixture()

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory, workspaceState: workspaceState)

        service.snapshot = .fixture(stagedChanges: [], unstagedChanges: [], untrackedChanges: [])
        await viewModel.commit(draft: GitCommitDraft(summary: "feat: sidebar", description: ""), workspaceState: workspaceState)

        #expect(service.committedDrafts.map(\.summary) == ["feat: sidebar"])
        #expect(viewModel.branchActionError == nil)
        #expect(viewModel.snapshot?.stagedChanges.isEmpty == true)
    }

    @Test func createBranchRefreshesSnapshotAndBranchList() async throws {
        let service = FakeGitService()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        service.snapshot = .fixture(branchName: "main")
        service.branches = [.init(name: "main", isCurrent: true)]

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory)

        service.snapshot = .fixture(branchName: "feature/git-sidebar")
        service.branches = [
            .init(name: "main", isCurrent: false),
            .init(name: "feature/git-sidebar", isCurrent: true)
        ]
        await viewModel.createBranch(named: "feature/git-sidebar", switchAfterCreate: true)

        #expect(service.createdBranches.count == 1)
        #expect(service.createdBranches.first?.name == "feature/git-sidebar")
        #expect(viewModel.snapshot?.branchName == "feature/git-sidebar")
    }

    @Test func fetchPullAndPushDelegateToService() async throws {
        let service = FakeGitService()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        service.snapshot = .fixture(branchName: "main")
        service.branches = [.init(name: "main", isCurrent: true)]

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory)
        await viewModel.fetch()
        await viewModel.pull()
        await viewModel.push()

        #expect(service.fetchedRepositoryRoots.count == 1)
        #expect(service.pulledRepositoryRoots.count == 1)
        #expect(service.pushedRepositoryRoots.count == 1)
    }

    @Test func stashActionsDelegateToService() async throws {
        let service = FakeGitService()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        service.snapshot = .fixture(branchName: "main")
        service.branches = [.init(name: "main", isCurrent: true)]

        let viewModel = GitPanelViewModel(gitService: service)
        await viewModel.refresh(for: workingDirectory)
        await viewModel.saveStash(message: "wip sidebar")
        await viewModel.applyStash(id: "stash@{0}", pop: true)

        #expect(service.savedStashMessages == ["wip sidebar"])
        #expect(service.appliedStashes.count == 1)
        #expect(service.appliedStashes.first?.id == "stash@{0}")
        #expect(service.appliedStashes.first?.pop == true)
    }
}

private final class FakeGitService: GitServicing {
    var snapshot: GitRepositorySnapshot?
    var snapshotError: GitServiceError?
    var diffText: String = ""
    var branches: [GitBranchReference] = []
    var refreshInputs: [URL] = []
    var diffRequests: [(path: String, staged: Bool, root: URL)] = []
    var switchedBranches: [String] = []
    var switchBranchError: GitServiceError?
    var stagedChanges: [String] = []
    var unstagedChanges: [String] = []
    var discardedChanges: [String] = []
    var committedDrafts: [GitCommitDraft] = []
    var fetchedRepositoryRoots: [URL] = []
    var pulledRepositoryRoots: [URL] = []
    var pushedRepositoryRoots: [URL] = []
    var createdBranches: [(name: String, switchAfterCreate: Bool)] = []
    var stashes: [GitStashEntry] = []
    var savedStashMessages: [String?] = []
    var appliedStashes: [(id: String, pop: Bool)] = []

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        refreshInputs.append(workingDirectory)
        if let snapshotError { throw snapshotError }
        return snapshot ?? .fixture()
    }

    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] {
        branches
    }

    func switchBranch(to branchName: String, repositoryRoot: URL) async throws {
        if let switchBranchError { throw switchBranchError }
        switchedBranches.append(branchName)
    }

    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        diffRequests.append((change.relativePath, staged, repositoryRoot))
        return diffText
    }

    func stage(change: GitFileChange, repositoryRoot: URL) async throws {
        stagedChanges.append(change.relativePath)
    }

    func unstage(change: GitFileChange, repositoryRoot: URL) async throws {
        unstagedChanges.append(change.relativePath)
    }

    func discard(change: GitFileChange, repositoryRoot: URL) async throws {
        discardedChanges.append(change.relativePath)
    }

    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {
        committedDrafts.append(draft)
    }

    func fetch(repositoryRoot: URL) async throws {
        fetchedRepositoryRoots.append(repositoryRoot)
    }

    func pull(repositoryRoot: URL) async throws {
        pulledRepositoryRoots.append(repositoryRoot)
    }

    func push(repositoryRoot: URL) async throws {
        pushedRepositoryRoots.append(repositoryRoot)
    }

    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {
        createdBranches.append((named, switchAfterCreate))
    }

    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] {
        stashes
    }

    func saveStash(message: String?, repositoryRoot: URL) async throws {
        savedStashMessages.append(message)
    }

    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {
        appliedStashes.append((id, pop))
    }
}

private extension GitRepositorySnapshot {
    static func fixture(
        branchName: String = "feature/basic-git",
        stagedChanges: [GitFileChange]? = nil,
        unstagedChanges: [GitFileChange]? = nil,
        untrackedChanges: [GitFileChange]? = nil
    ) -> GitRepositorySnapshot {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let defaultStaged = [
            GitFileChange(
                relativePath: "agentGui/Views/FileEditorView.swift",
                absoluteURL: root.appending(path: "agentGui/Views/FileEditorView.swift"),
                status: .modified,
                section: .staged
            )
        ]
        let defaultUnstaged = [
            GitFileChange(
                relativePath: "agentGui/Views/WorkspacePanelView.swift",
                absoluteURL: root.appending(path: "agentGui/Views/WorkspacePanelView.swift"),
                status: .modified,
                section: .modified
            )
        ]
        let defaultUntracked = [
            GitFileChange(
                relativePath: "docs/spec/basic.md",
                absoluteURL: root.appending(path: "docs/spec/basic.md"),
                status: .untracked,
                section: .untracked
            )
        ]

        return GitRepositorySnapshot(
            repositoryRoot: root,
            repositoryName: "repo",
            branchName: branchName,
            hasRemoteTrackingBranch: true,
            aheadCount: 1,
            behindCount: 0,
            stagedChanges: stagedChanges ?? defaultStaged,
            unstagedChanges: unstagedChanges ?? defaultUnstaged,
            untrackedChanges: untrackedChanges ?? defaultUntracked
        )
    }
}