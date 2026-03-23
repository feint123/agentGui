import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct GitPanelViewTests {
    @Test func gitPanelCanBeCreatedWithSnapshotBackedEnvironment() {
        let panel = GitPanelViewModel(gitService: GitPanelViewTestsFakeService())
        panel.snapshot = .fixture()

        let view = GitPanelView(showsBackground: false)
            .environment(panel)
            .environment(WorkspaceState())

        #expect(view != nil)
        #expect(panel.snapshot?.repositoryName == "repo")
    }
}

private final class GitPanelViewTestsFakeService: GitServicing {
    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        .fixture()
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

    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {}

    func fetch(repositoryRoot: URL) async throws {}

    func pull(repositoryRoot: URL) async throws {}

    func push(repositoryRoot: URL) async throws {}

    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {}

    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] { [] }

    func saveStash(message: String?, repositoryRoot: URL) async throws {}

    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {}
}

private extension GitRepositorySnapshot {
    static func fixture(
        branchName: String = "main",
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