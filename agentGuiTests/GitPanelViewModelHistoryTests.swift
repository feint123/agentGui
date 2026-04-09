import XCTest
@testable import agentGui

// MARK: - Stub GitServicing

@MainActor
private final class StubGitService: GitServicing {

    var commitsToReturn: [GitCommit] = []
    var shouldThrow = false

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        GitRepositorySnapshot(
            repositoryRoot: workingDirectory,
            repositoryName: "test",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0,
            behindCount: 0,
            stagedChanges: [],
            unstagedChanges: [],
            untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to branchName: String, repositoryRoot: URL) async throws {}
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String { "" }
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
    func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] {
        if shouldThrow { throw GitServiceError.commandFailed("stub error") }
        return commitsToReturn
    }
    func stageAll(repositoryRoot: URL) async throws {}
    func unstageAll(repositoryRoot: URL) async throws {}
}

// MARK: - Tests

@MainActor
final class GitPanelViewModelHistoryTests: XCTestCase {

    func test_refresh_populatesHistoryEntries() async {
        let stub = StubGitService()
        stub.commitsToReturn = [
            GitCommit(
                sha: "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111",
                message: "fix: something",
                fullMessage: "fix: something",
                author: "Dev",
                authorEmail: "dev@dev.com",
                date: Date()
            )
        ]
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        XCTAssertEqual(vm.historyEntries.count, 1)
        XCTAssertEqual(vm.historyEntries[0].message, "fix: something")
    }

    func test_refresh_historyServiceError_doesNotCrash() async {
        let stub = StubGitService()
        stub.shouldThrow = true
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        // 历史加载失败时应静默，不影响主要状态
        XCTAssertTrue(vm.historyEntries.isEmpty)
    }

    func test_loadMoreHistory_appendsEntries() async {
        let stub = StubGitService()
        stub.commitsToReturn = (0..<10).map { i in
            GitCommit(
                sha: "sha\(i)" + String(repeating: "0", count: 37 - "sha\(i)".count),
                message: "commit \(i)",
                fullMessage: "commit \(i)",
                author: "Author",
                authorEmail: "a@b.com",
                date: Date()
            )
        }
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        let countAfterFirst = vm.historyEntries.count
        await vm.loadMoreHistory()
        XCTAssertGreaterThanOrEqual(vm.historyEntries.count, countAfterFirst)
    }
}
