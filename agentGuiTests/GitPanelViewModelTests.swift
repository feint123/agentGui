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

    @Test func requestDiscardOnlyStoresPendingAction() async throws {
        let service = FakeGitService()
        let viewModel = GitPanelViewModel(gitService: service)
        let change = GitRepositorySnapshot.fixture().unstagedChanges[0]

        viewModel.requestDiscard(change)

        #expect(service.discardedPaths.isEmpty)
        #expect(viewModel.pendingDangerousAction == .discard(change))
    }

    @Test func confirmPendingActionExecutesAndRefreshes() async throws {
        let service = FakeGitService()
        service.snapshot = .fixture(branchName: "main")
        let viewModel = GitPanelViewModel(gitService: service)
        let change = GitRepositorySnapshot.fixture().untrackedChanges[0]

        viewModel.currentWorkingDirectory = URL(fileURLWithPath: "/tmp/repo")
        viewModel.requestClean(change)
        await viewModel.confirmPendingAction()

        #expect(service.cleanedPaths == ["docs/spec/basic.md"])
        #expect(service.refreshInputs == [URL(fileURLWithPath: "/tmp/repo")])
        #expect(viewModel.pendingDangerousAction == nil)
    }

    @Test func canCommitRequiresStagedChangesAndMessage() async throws {
        let service = FakeGitService()
        let viewModel = GitPanelViewModel(gitService: service)

        #expect(!viewModel.canCommit)

        viewModel.snapshot = .fixture()
        #expect(!viewModel.canCommit)

        viewModel.commitMessage = "feat: add git ui"
        #expect(viewModel.canCommit)
    }
}

private final class FakeGitService: GitServicing {
    var snapshot: GitRepositorySnapshot?
    var snapshotError: GitServiceError?
    var diffText: String = ""
    var refreshInputs: [URL] = []
    var diffRequests: [(path: String, staged: Bool, root: URL)] = []
    var stagedPaths: [String] = []
    var unstagedPaths: [String] = []
    var discardedPaths: [String] = []
    var cleanedPaths: [String] = []
    var stageAllCount = 0
    var commitMessages: [String] = []

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        refreshInputs.append(workingDirectory)
        if let snapshotError { throw snapshotError }
        return snapshot ?? .fixture()
    }

    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        diffRequests.append((change.relativePath, staged, repositoryRoot))
        return diffText
    }

    func stage(path: String, repositoryRoot: URL) async throws {
        stagedPaths.append(path)
    }

    func stageAll(repositoryRoot: URL) async throws {
        stageAllCount += 1
    }

    func unstage(path: String, repositoryRoot: URL) async throws {
        unstagedPaths.append(path)
    }

    func discard(path: String, repositoryRoot: URL) async throws {
        discardedPaths.append(path)
    }

    func cleanUntracked(path: String, repositoryRoot: URL) async throws {
        cleanedPaths.append(path)
    }

    func commit(message: String, repositoryRoot: URL) async throws {
        commitMessages.append(message)
    }
}

private extension GitRepositorySnapshot {
    static func fixture(branchName: String = "feature/basic-git") -> GitRepositorySnapshot {
        let root = URL(fileURLWithPath: "/tmp/repo")
        return GitRepositorySnapshot(
            repositoryRoot: root,
            repositoryName: "repo",
            branchName: branchName,
            hasRemoteTrackingBranch: true,
            aheadCount: 1,
            behindCount: 0,
            stagedChanges: [
                GitFileChange(
                    relativePath: "agentGui/Views/FileEditorView.swift",
                    absoluteURL: root.appending(path: "agentGui/Views/FileEditorView.swift"),
                    status: .modified,
                    section: .staged
                )
            ],
            unstagedChanges: [
                GitFileChange(
                    relativePath: "agentGui/Views/WorkspacePanelView.swift",
                    absoluteURL: root.appending(path: "agentGui/Views/WorkspacePanelView.swift"),
                    status: .modified,
                    section: .modified
                )
            ],
            untrackedChanges: [
                GitFileChange(
                    relativePath: "docs/spec/basic.md",
                    absoluteURL: root.appending(path: "docs/spec/basic.md"),
                    status: .untracked,
                    section: .untracked
                )
            ]
        )
    }
}