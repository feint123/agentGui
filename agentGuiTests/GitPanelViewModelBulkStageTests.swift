import XCTest
@testable import agentGui

// MARK: - Spy

@MainActor
private final class BulkStageSpyGitService: GitServicing {
    var stageAllCallCount = 0
    var unstageAllCallCount = 0
    var stageAllShouldThrow = false
    var snapshotToReturn: GitRepositorySnapshot?

    private func defaultRoot() -> URL { URL(fileURLWithPath: "/repo") }

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        snapshotToReturn ?? GitRepositorySnapshot(
            repositoryRoot: defaultRoot(),
            repositoryName: "repo",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [], unstagedChanges: [], untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to: String, repositoryRoot: URL) async throws {}
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
    func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] { [] }
    func stageAll(repositoryRoot: URL) async throws {
        if stageAllShouldThrow { throw GitServiceError.commandFailed("stub error") }
        stageAllCallCount += 1
    }
    func unstageAll(repositoryRoot: URL) async throws { unstageAllCallCount += 1 }
}

// MARK: - GitPanelViewModel bulk stage tests

@MainActor
final class GitPanelViewModelBulkStageTests: XCTestCase {

    func test_stageAll_callsServiceStageAll() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.stageAll()

        XCTAssertEqual(spy.stageAllCallCount, 1)
    }

    func test_unstageAll_callsServiceUnstageAll() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.unstageAll()

        XCTAssertEqual(spy.unstageAllCallCount, 1)
    }

    func test_stageAll_triggersRefreshAfterOperation() async {
        let spy = BulkStageSpyGitService()
        spy.snapshotToReturn = GitRepositorySnapshot(
            repositoryRoot: URL(fileURLWithPath: "/repo"),
            repositoryName: "repo",
            branchName: "feat",
            hasRemoteTrackingBranch: false,
            aheadCount: 0, behindCount: 0,
            stagedChanges: [],
            unstagedChanges: [],
            untrackedChanges: []
        )
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")

        await vm.stageAll()

        XCTAssertNotNil(vm.snapshot)
        XCTAssertEqual(vm.snapshot?.branchName, "feat")
    }

    func test_stageAll_serviceFailure_capturesBranchActionError() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        vm.currentWorkingDirectory = URL(fileURLWithPath: "/repo")
        spy.stageAllShouldThrow = true

        await vm.stageAll()

        XCTAssertNotNil(vm.branchActionError)
    }

    func test_unstageAll_noRepositoryRoot_doesNothing() async {
        let spy = BulkStageSpyGitService()
        let vm = GitPanelViewModel(gitService: spy)
        // currentWorkingDirectory 和 snapshot 均为 nil

        await vm.unstageAll()

        XCTAssertEqual(spy.unstageAllCallCount, 0)
    }
}
