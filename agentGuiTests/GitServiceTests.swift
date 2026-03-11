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
        #expect(runner.invocations[1].arguments == ["status", "--porcelain=v1", "--branch"])
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

    @Test func fileMutationCommandsUseExpectedArguments() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)
        let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

        runner.results = Array(repeating: .success(.init(stdout: "", stderr: "", exitCode: 0)), count: 5)

        try await service.stage(path: "file.swift", repositoryRoot: repositoryRoot)
        try await service.stageAll(repositoryRoot: repositoryRoot)
        try await service.unstage(path: "file.swift", repositoryRoot: repositoryRoot)
        try await service.discard(path: "file.swift", repositoryRoot: repositoryRoot)
        try await service.cleanUntracked(path: "file.swift", repositoryRoot: repositoryRoot)

        #expect(runner.invocations.map(\.arguments) == [
            ["add", "--", "file.swift"],
            ["add", "--all"],
            ["restore", "--staged", "--", "file.swift"],
            ["restore", "--", "file.swift"],
            ["clean", "-f", "--", "file.swift"]
        ])
    }

    @Test func commitRejectsEmptyMessageBeforeRunningGit() async throws {
        let runner = FakeGitCommandRunner()
        let service = GitService(commandRunner: runner)

        await #expect(throws: GitServiceError.emptyCommitMessage) {
            try await service.commit(message: "   ", repositoryRoot: URL(fileURLWithPath: "/tmp/repo"))
        }

        #expect(runner.invocations.isEmpty)
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