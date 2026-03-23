import Foundation
import Observation

@Observable
@MainActor
final class GitPanelViewModel {
    var snapshot: GitRepositorySnapshot?
    var isLoading = false
    var loadError: String?
    var branchActionError: String?
    var selectedChange: GitFileChange?
    var selectedDiffSection: GitChangeSection?
    var selectedDiffText: String?
    var availableBranches: [GitBranchReference] = []
    var isSwitchingBranch = false
    var currentWorkingDirectory: URL?
    var operationState: GitOperationState = .idle
    var stashEntries: [GitStashEntry] = []

    private let gitService: GitServicing

    init(gitService: GitServicing? = nil) {
        self.gitService = gitService ?? GitService()
    }

    func refresh(for workingDirectory: URL, workspaceState: WorkspaceState? = nil) async {
        currentWorkingDirectory = workingDirectory
        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await gitService.repositorySnapshot(for: workingDirectory)
            let branches = try await gitService.listBranches(repositoryRoot: snapshot.repositoryRoot)
            let stashes = try await gitService.listStashes(repositoryRoot: snapshot.repositoryRoot)
            self.snapshot = snapshot
            availableBranches = branches
            stashEntries = stashes
            reconcileSelection(with: workspaceState)
            loadError = nil
            branchActionError = nil
            operationState = .idle
        } catch GitServiceError.notAGitRepository {
            snapshot = nil
            availableBranches = []
            stashEntries = []
            loadError = nil
            branchActionError = nil
            operationState = .idle
            clearSelection(in: workspaceState)
        } catch {
            snapshot = nil
            availableBranches = []
            stashEntries = []
            loadError = error.localizedDescription
            branchActionError = nil
            clearSelection(in: workspaceState)
        }
    }

    func switchBranch(to branchName: String) async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }

        isSwitchingBranch = true
        defer { isSwitchingBranch = false }

        do {
            try await gitService.switchBranch(to: branchName, repositoryRoot: repositoryRoot)
            branchActionError = nil
            await refresh(for: repositoryRoot)
        } catch {
            branchActionError = error.localizedDescription
        }
    }

    func stage(change: GitFileChange, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在暂存", action: { repositoryRoot in
            try await gitService.stage(change: change, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func unstage(change: GitFileChange, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在取消暂存", action: { repositoryRoot in
            try await gitService.unstage(change: change, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func discard(change: GitFileChange, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在丢弃更改", action: { repositoryRoot in
            try await gitService.discard(change: change, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func commit(draft: GitCommitDraft, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在提交", action: { repositoryRoot in
            try await gitService.commit(draft: draft, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func createBranch(named: String, switchAfterCreate: Bool, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在创建分支", action: { repositoryRoot in
            try await gitService.createBranch(named: named, switchAfterCreate: switchAfterCreate, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func fetch(workspaceState: WorkspaceState? = nil) async {
        await mutate("正在获取远端", action: { repositoryRoot in
            try await gitService.fetch(repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func pull(workspaceState: WorkspaceState? = nil) async {
        await mutate("正在拉取更新", action: { repositoryRoot in
            try await gitService.pull(repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func push(workspaceState: WorkspaceState? = nil) async {
        await mutate("正在推送提交", action: { repositoryRoot in
            try await gitService.push(repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func saveStash(message: String?, workspaceState: WorkspaceState? = nil) async {
        await mutate("正在保存暂存", action: { repositoryRoot in
            try await gitService.saveStash(message: message, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func applyStash(id: String, pop: Bool, workspaceState: WorkspaceState? = nil) async {
        await mutate(pop ? "正在恢复并移除暂存" : "正在恢复暂存", action: { repositoryRoot in
            try await gitService.applyStash(id: id, pop: pop, repositoryRoot: repositoryRoot)
        }, workspaceState: workspaceState)
    }

    func selectDiff(for change: GitFileChange, staged: Bool, workspaceState: WorkspaceState) async {
        let repositoryRoot = snapshot?.repositoryRoot
            ?? currentWorkingDirectory
            ?? change.absoluteURL.deletingLastPathComponent()

        do {
            let diffText = try await gitService.diff(for: change, staged: staged, repositoryRoot: repositoryRoot)
            selectedChange = change
            selectedDiffSection = change.section
            selectedDiffText = diffText
            workspaceState.showGitDiffDetail(
                path: change.absoluteURL,
                title: change.relativePath,
                diffText: diffText
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reconcileSelection(with workspaceState: WorkspaceState?) {
        guard let selectedChange else { return }
        let allChanges = (snapshot?.stagedChanges ?? []) + (snapshot?.unstagedChanges ?? []) + (snapshot?.untrackedChanges ?? [])
        if let updatedChange = allChanges.first(where: { $0.id == selectedChange.id }) {
            self.selectedChange = updatedChange
            if workspaceState?.selectedGitDiffPath == selectedChange.absoluteURL {
                workspaceState?.selectedGitDiffPath = updatedChange.absoluteURL
                workspaceState?.selectedGitDiffTitle = updatedChange.relativePath
            }
            return
        }

        clearSelection(in: workspaceState)
    }

    private func clearSelection(in workspaceState: WorkspaceState?) {
        selectedChange = nil
        selectedDiffSection = nil
        selectedDiffText = nil
        workspaceState?.clearGitDiffSelection()
    }

    private func mutate(
        _ operationLabel: String,
        action: (URL) async throws -> Void,
        workspaceState: WorkspaceState?
    ) async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }

        operationState = .running(operationLabel)
        do {
            try await action(repositoryRoot)
            branchActionError = nil
            await refresh(for: repositoryRoot, workspaceState: workspaceState)
            operationState = .idle
        } catch {
            branchActionError = error.localizedDescription
            operationState = .failed(error.localizedDescription)
        }
    }
}