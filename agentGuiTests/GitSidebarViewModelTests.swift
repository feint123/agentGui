import Foundation
import Testing
@testable import agentGui

@MainActor
struct GitSidebarViewModelTests {

    @Test func commitRequiresNonEmptySummary() async throws {
        let panel = GitPanelViewModel(gitService: FakeSidebarGitService())
        panel.snapshot = GitRepositorySnapshot.sidebarFixture(stagedChanges: [])
        let sidebar = GitSidebarViewModel(panelViewModel: panel)

        sidebar.commitDraft = GitCommitDraft(summary: "   ", description: "")

        #expect(sidebar.commitDisabledReason == .missingSummary)
    }

    @Test func commitRequiresStagedChanges() async throws {
        let panel = GitPanelViewModel(gitService: FakeSidebarGitService())
        panel.snapshot = GitRepositorySnapshot.sidebarFixture(stagedChanges: [])
        let sidebar = GitSidebarViewModel(panelViewModel: panel)

        sidebar.commitDraft = GitCommitDraft(summary: "feat: sidebar", description: "")

        #expect(sidebar.commitDisabledReason == .noStagedChanges)
    }

    @Test func filteredChangesMatchesLocalizedInput() async throws {
        let panel = GitPanelViewModel(gitService: FakeSidebarGitService())
        panel.snapshot = GitRepositorySnapshot.sidebarFixture()
        let sidebar = GitSidebarViewModel(panelViewModel: panel)

        sidebar.changeFilterText = "WorkspacePanel"

        #expect(sidebar.filteredUnstagedChanges.count == 1)
        #expect(sidebar.filteredStagedChanges.isEmpty)
        #expect(sidebar.filteredUntrackedChanges.isEmpty)
    }

    @Test func saveStashDisabledWithoutLocalChanges() async throws {
        let panel = GitPanelViewModel(gitService: FakeSidebarGitService())
        panel.snapshot = GitRepositorySnapshot.sidebarFixture(stagedChanges: [], unstagedChanges: [], untrackedChanges: [])
        let sidebar = GitSidebarViewModel(panelViewModel: panel)

        #expect(sidebar.canSaveStash == false)
    }

    @Test func commitDelegatesToPanelAndClearsDraftOnSuccess() async throws {
        let service = FakeSidebarGitService()
        let panel = GitPanelViewModel(gitService: service)
        let workspaceState = WorkspaceState()
        let workingDirectory = URL(fileURLWithPath: "/tmp/repo")
        service.snapshot = GitRepositorySnapshot.sidebarFixture()

        await panel.refresh(for: workingDirectory, workspaceState: workspaceState)

        let sidebar = GitSidebarViewModel(panelViewModel: panel)
        sidebar.commitDraft = GitCommitDraft(summary: "feat: sidebar", description: "")
        service.snapshot = GitRepositorySnapshot.sidebarFixture(stagedChanges: [], unstagedChanges: [], untrackedChanges: [])

        await sidebar.commit(workspaceState: workspaceState)

        #expect(service.committedDrafts.map(\.summary) == ["feat: sidebar"])
        #expect(sidebar.commitDraft.summary.isEmpty)
        #expect(sidebar.commitDraft.description.isEmpty)
    }

    @Test func commitPreservesDraftWhenValidationFails() async throws {
        let service = FakeSidebarGitService()
        let panel = GitPanelViewModel(gitService: service)
        panel.snapshot = GitRepositorySnapshot.sidebarFixture(stagedChanges: [])
        let sidebar = GitSidebarViewModel(panelViewModel: panel)
        sidebar.commitDraft = GitCommitDraft(summary: "feat: sidebar", description: "")

        await sidebar.commit(workspaceState: WorkspaceState())

        #expect(service.committedDrafts.isEmpty)
        #expect(sidebar.commitDraft.summary == "feat: sidebar")
    }

    @Test func syncAvailabilityFollowsRemoteTrackingBranch() async throws {
        let panel = GitPanelViewModel(gitService: FakeSidebarGitService())
        panel.snapshot = GitRepositorySnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            repositoryName: "repo",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0,
            behindCount: 0,
            stagedChanges: [],
            unstagedChanges: [],
            untrackedChanges: []
        )
        let sidebar = GitSidebarViewModel(panelViewModel: panel)

        #expect(sidebar.canSync == false)
    }
}

private final class FakeSidebarGitService: GitServicing {
    var snapshot = GitRepositorySnapshot.sidebarFixture()
    var committedDrafts: [GitCommitDraft] = []

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        snapshot
    }

    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] {
        [.init(name: "main", isCurrent: true)]
    }

    func switchBranch(to branchName: String, repositoryRoot: URL) async throws {}

    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        "diff --git a/file b/file"
    }

    func stage(change: GitFileChange, repositoryRoot: URL) async throws {}

    func unstage(change: GitFileChange, repositoryRoot: URL) async throws {}

    func discard(change: GitFileChange, repositoryRoot: URL) async throws {}

    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {
        committedDrafts.append(draft)
    }

    func fetch(repositoryRoot: URL) async throws {}

    func pull(repositoryRoot: URL) async throws {}

    func push(repositoryRoot: URL) async throws {}

    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {}

    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] { [] }

    func saveStash(message: String?, repositoryRoot: URL) async throws {}

    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {}
}

private extension GitRepositorySnapshot {
    static func sidebarFixture(
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
            branchName: "main",
            hasRemoteTrackingBranch: true,
            aheadCount: 1,
            behindCount: 0,
            stagedChanges: stagedChanges ?? defaultStaged,
            unstagedChanges: unstagedChanges ?? defaultUnstaged,
            untrackedChanges: untrackedChanges ?? defaultUntracked
        )
    }
}