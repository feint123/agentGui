import Foundation
import Observation

@Observable
@MainActor
final class GitSidebarViewModel {
    let panelViewModel: GitPanelViewModel
    var changeFilterText = ""
    var commitDraft = GitCommitDraft()
    var operationState: GitOperationState = .idle
    var pendingDiscardChange: GitFileChange?
    var newBranchName = ""
    var stashMessage = ""

    init(panelViewModel: GitPanelViewModel) {
        self.panelViewModel = panelViewModel
    }

    var snapshot: GitRepositorySnapshot? {
        panelViewModel.snapshot
    }

    var commitDisabledReason: GitCommitDisabledReason? {
        let summary = commitDraft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return .missingSummary }
        guard !(snapshot?.stagedChanges.isEmpty ?? true) else { return .noStagedChanges }
        return nil
    }

    var filteredStagedChanges: [GitFileChange] {
        filter(snapshot?.stagedChanges ?? [])
    }

    var filteredUnstagedChanges: [GitFileChange] {
        filter(snapshot?.unstagedChanges ?? [])
    }

    var filteredUntrackedChanges: [GitFileChange] {
        filter(snapshot?.untrackedChanges ?? [])
    }

    var canSaveStash: Bool {
        guard let snapshot else { return false }
        return !snapshot.stagedChanges.isEmpty || !snapshot.unstagedChanges.isEmpty || !snapshot.untrackedChanges.isEmpty
    }

    var canSync: Bool {
        snapshot?.hasRemoteTrackingBranch == true
    }

    func commit(workspaceState: WorkspaceState) async {
        guard commitDisabledReason == nil else { return }
        await panelViewModel.commit(draft: commitDraft, workspaceState: workspaceState)
        if panelViewModel.branchActionError == nil {
            commitDraft = GitCommitDraft()
        }
    }

    func requestDiscard(_ change: GitFileChange) {
        pendingDiscardChange = change
    }

    func confirmDiscard(workspaceState: WorkspaceState) async {
        guard let pendingDiscardChange else { return }
        await panelViewModel.discard(change: pendingDiscardChange, workspaceState: workspaceState)
        if panelViewModel.branchActionError == nil {
            self.pendingDiscardChange = nil
        }
    }

    func cancelDiscard() {
        pendingDiscardChange = nil
    }

    func createBranch(switchAfterCreate: Bool, workspaceState: WorkspaceState) async {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await panelViewModel.createBranch(named: name, switchAfterCreate: switchAfterCreate, workspaceState: workspaceState)
        if panelViewModel.branchActionError == nil {
            newBranchName = ""
        }
    }

    func saveStash(workspaceState: WorkspaceState) async {
        guard canSaveStash else { return }
        let message = stashMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        await panelViewModel.saveStash(message: message.isEmpty ? nil : message, workspaceState: workspaceState)
        if panelViewModel.branchActionError == nil {
            stashMessage = ""
        }
    }

    private func filter(_ changes: [GitFileChange]) -> [GitFileChange] {
        let query = changeFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return changes }
        return changes.filter { $0.relativePath.localizedStandardContains(query) }
    }
}