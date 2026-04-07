import XCTest
@testable import agentGui

// MARK: - Stub

@MainActor
private final class StubCommandRunner: GitCommandRunning {
    var stubbedResult: GitCommandResult = .init(stdout: "", stderr: "", exitCode: 0)

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        stubbedResult
    }
}

// MARK: - Tests

@MainActor
final class GitServiceListCommitsTests: XCTestCase {

    private let repoURL = URL(fileURLWithPath: "/fake/repo")

    func test_listCommits_parsesReturnedCommits() async throws {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(
            stdout: """
            ---COMMIT---
            aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000
            feat: initial commit
            Dev
            dev@example.com
            2026-04-06T12:00:00+08:00
            feat: initial commit
            ---END---
            """,
            stderr: "",
            exitCode: 0
        )
        let service = GitService(commandRunner: stub)
        let commits = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].sha, "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000")
        XCTAssertEqual(commits[0].author, "Dev")
    }

    func test_listCommits_commandFailed_throws() async {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(stdout: "", stderr: "fatal: not a git repo", exitCode: 128)
        let service = GitService(commandRunner: stub)
        do {
            _ = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
    }

    func test_listCommits_empty_returnsEmptyArray() async throws {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(stdout: "", stderr: "", exitCode: 0)
        let service = GitService(commandRunner: stub)
        let commits = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
        XCTAssertTrue(commits.isEmpty)
    }
}
