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