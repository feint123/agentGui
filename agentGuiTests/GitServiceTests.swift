import Foundation
import Testing
@testable import agentGui

@MainActor
struct GitServiceTests {

    @Test func repositorySnapshotResolvesRepositoryRootFromSubdirectory() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)

        let workspaceURL = URL(fileURLWithPath: "/tmp/repo/agentGui/Views")
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: repositoryRoot.path + "\n", stderr: "", exitCode: 0)),
            .success(.init(stdout: "## main\n M changed.swift\n", stderr: "", exitCode: 0))
        ]

        let snapshot = try await service.repositorySnapshot(for: workspaceURL)

        #expect(snapshot.repositoryRoot == repositoryRoot)
        #expect(snapshot.branchName == "main")
        #expect(runner.invocations.count == 2)
        #expect(runner.invocations[0].arguments == ["rev-parse", "--show-toplevel"])
        #expect(runner.invocations[0].workingDirectory == workspaceURL)
        #expect(runner.invocations[1].arguments == ["-c", "core.quotepath=false", "status", "--porcelain=v1", "--branch"])
        #expect(runner.invocations[1].workingDirectory == repositoryRoot)
    }

    @Test func repositorySnapshotMapsNonRepositoryError() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)

        runner.results = [
            .success(.init(stdout: "", stderr: "fatal: not a git repository", exitCode: 128))
        ]

        await #expect(throws: GitServiceError.notAGitRepository) {
            try await service.repositorySnapshot(for: URL(fileURLWithPath: "/tmp/not-repo"))
        }
    }

    @Test func diffUsesCachedFlagForStagedChanges() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "agentGui/Views/FileEditorView.swift",
            absoluteURL: repositoryRoot.appending(path: "agentGui/Views/FileEditorView.swift"),
            status: .modified,
            section: .staged
        )

        runner.results = [
            .success(.init(stdout: "diff --git a/file b/file", stderr: "", exitCode: 0))
        ]

        _ = try await service.diff(for: change, staged: true, repositoryRoot: repositoryRoot)

        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].arguments == ["diff", "--cached", "--", "agentGui/Views/FileEditorView.swift"])
    }

    @Test func diffPreservesChinesePathArgument() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "文档/需求说明.md",
            absoluteURL: repositoryRoot.appending(path: "文档/需求说明.md"),
            status: .modified,
            section: .modified
        )

        runner.results = [
            .success(.init(stdout: "diff --git a/file b/file", stderr: "", exitCode: 0))
        ]

        _ = try await service.diff(for: change, staged: false, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["diff", "--", "文档/需求说明.md"])
    }

    @Test func listBranchesUsesExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "* main\n  feature/sidebar\n", stderr: "", exitCode: 0))
        ]

        let branches = try await service.listBranches(repositoryRoot: repositoryRoot)

        #expect(branches.map(\.name) == ["main", "feature/sidebar"])
        #expect(branches.first?.isCurrent == true)
        #expect(runner.invocations[0].arguments == ["branch", "--list"])
    }

    @Test func switchBranchUsesExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.switchBranch(to: "feature/sidebar", repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["switch", "feature/sidebar"])
    }

    @Test func switchBranchMapsCommandFailureToUserFacingMessage() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "fatal: invalid reference: missing-branch", exitCode: 128))
        ]

        await #expect(throws: GitServiceError.commandFailed("fatal: invalid reference: missing-branch")) {
            try await service.switchBranch(to: "missing-branch", repositoryRoot: repositoryRoot)
        }
    }

    @Test func stageUsesAddArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "agentGui/Views/FileEditorView.swift",
            absoluteURL: repositoryRoot.appending(path: "agentGui/Views/FileEditorView.swift"),
            status: .modified,
            section: .modified
        )

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.stage(change: change, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["add", "--", change.relativePath])
    }

    @Test func unstageUsesRestoreStagedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "agentGui/Views/FileEditorView.swift",
            absoluteURL: repositoryRoot.appending(path: "agentGui/Views/FileEditorView.swift"),
            status: .modified,
            section: .staged
        )

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.unstage(change: change, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["restore", "--staged", "--", change.relativePath])
    }

    @Test func discardUsesRestoreArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
        let change = GitFileChange(
            relativePath: "agentGui/Views/FileEditorView.swift",
            absoluteURL: repositoryRoot.appending(path: "agentGui/Views/FileEditorView.swift"),
            status: .modified,
            section: .modified
        )

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.discard(change: change, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["restore", "--", change.relativePath])
    }

    @Test func commitUsesMessageFileWhenDescriptionExists() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.commit(
            draft: GitCommitDraft(summary: "feat: add git actions", description: "Implements file-level stage and discard."),
            repositoryRoot: repositoryRoot
        )

        #expect(runner.invocations[0].arguments.first == "commit")
        #expect(runner.invocations[0].arguments.contains("--file"))
    }

    @Test func commitRejectsEmptySummary() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        await #expect(throws: GitServiceError.commandFailed("提交说明不能为空。")) {
            try await service.commit(draft: GitCommitDraft(summary: "   ", description: ""), repositoryRoot: repositoryRoot)
        }

        #expect(runner.invocations.isEmpty)
    }

    @Test func fetchUsesExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.fetch(repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["fetch", "--all", "--prune"])
    }

    @Test func pullUsesExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.pull(repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["pull", "--ff-only"])
    }

    @Test func pushUsesExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.push(repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["push"])
    }

    @Test func createBranchUsesSwitchCreateArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.createBranch(named: "feature/git-sidebar", switchAfterCreate: true, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["switch", "-c", "feature/git-sidebar"])
    }

    @Test func listStashesParsesIdentifierAndSummary() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "stash@{0}\u{1f}WIP on main: sidebar work\nstash@{1}\u{1f}On feature: save point\n", stderr: "", exitCode: 0))
        ]

        let entries = try await service.listStashes(repositoryRoot: repositoryRoot)

        #expect(entries.map(\.id) == ["stash@{0}", "stash@{1}"])
        #expect(entries.map(\.summary) == ["WIP on main: sidebar work", "On feature: save point"])
    }

    @Test func saveStashUsesPushArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.saveStash(message: "wip git sidebar", repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["stash", "push", "-m", "wip git sidebar"])
    }

    @Test func popStashUsesPopArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = [
            .success(.init(stdout: "", stderr: "", exitCode: 0))
        ]

        try await service.applyStash(id: "stash@{0}", pop: true, repositoryRoot: repositoryRoot)

        #expect(runner.invocations[0].arguments == ["stash", "pop", "stash@{0}"])
    }
}

private final class FakeGitCommandRunner: GitCommandRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    var invocations: [Invocation] = []
    var results: [Result<GitCommandResult, Error>] = []

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        invocations.append(.init(arguments: arguments, workingDirectory: workingDirectory))
        guard !results.isEmpty else {
            Issue.record("Missing fake result for invocation: \(arguments)")
            throw CancellationError()
        }
        return try results.removeFirst().get()
    }
}