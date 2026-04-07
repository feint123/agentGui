import XCTest
@testable import agentGui

@MainActor
final class GitCommitTests: XCTestCase {

    func test_shortSha_returns7Chars() {
        let commit = GitCommit(
            sha: "abcdef1234567890",
            message: "fix: handle nil",
            fullMessage: "fix: handle nil\n\nDetails here.",
            author: "Alice",
            authorEmail: "alice@example.com",
            date: Date()
        )
        XCTAssertEqual(commit.shortSha, "abcdef1")
    }

    func test_shortSha_withShortSha_returnsAll() {
        let commit = GitCommit(
            sha: "abc",
            message: "wip",
            fullMessage: "wip",
            author: "Bob",
            authorEmail: "bob@example.com",
            date: Date()
        )
        XCTAssertEqual(commit.shortSha, "abc")
    }

    func test_identifiable_idEqualsSha() {
        let commit = GitCommit(
            sha: "aabbccdd",
            message: "test",
            fullMessage: "test",
            author: "C",
            authorEmail: "c@c.com",
            date: Date()
        )
        XCTAssertEqual(commit.id, "aabbccdd")
    }
}
