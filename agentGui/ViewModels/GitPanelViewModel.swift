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
            self.snapshot = snapshot
            availableBranches = branches
            reconcileSelection(with: workspaceState)
            loadError = nil
            branchActionError = nil
        } catch GitServiceError.notAGitRepository {
            snapshot = nil
            availableBranches = []
            loadError = nil
            branchActionError = nil
            clearSelection(in: workspaceState)
        } catch {
            snapshot = nil
            availableBranches = []
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

    func selectDiff(for change: GitFileChange, staged: Bool, workspaceState: WorkspaceState) async {
        let repositoryRoot = snapshot?.repositoryRoot
            ?? currentWorkingDirectory
            ?? change.absoluteURL.deletingLastPathComponent()

        do {
            let diffText = try await gitService.diff(for: change, staged: staged, repositoryRoot: repositoryRoot)
            selectedChange = change
            selectedDiffSection = change.section
            selectedDiffText = diffText
            workspaceState.selectedGitDiffPath = change.absoluteURL
            workspaceState.selectedGitDiffText = diffText
            workspaceState.selectedGitDiffTitle = change.relativePath
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
}