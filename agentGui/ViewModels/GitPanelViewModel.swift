import Foundation
import Observation

enum GitDangerousAction: Equatable {
    case discard(GitFileChange)
    case clean(GitFileChange)

    var change: GitFileChange {
        switch self {
        case .discard(let change), .clean(let change):
            return change
        }
    }
}

@Observable
@MainActor
final class GitPanelViewModel {
    var snapshot: GitRepositorySnapshot?
    var isLoading = false
    var loadError: String?
    var selectedChange: GitFileChange?
    var selectedDiffIsStaged = false
    var selectedDiffText: String?
    var commitMessage = ""
    var transientBanner: String?
    var pendingDangerousAction: GitDangerousAction?
    var currentWorkingDirectory: URL?

    var canCommit: Bool {
        guard let snapshot else { return false }
        return !snapshot.stagedChanges.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let gitService: GitServicing

    init(gitService: GitServicing? = nil) {
        self.gitService = gitService ?? GitService()
    }

    func refresh(for workingDirectory: URL) async {
        currentWorkingDirectory = workingDirectory
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await gitService.repositorySnapshot(for: workingDirectory)
            loadError = nil
        } catch GitServiceError.notAGitRepository {
            snapshot = nil
            loadError = nil
        } catch {
            snapshot = nil
            loadError = error.localizedDescription
        }
    }

    func selectDiff(for change: GitFileChange, staged: Bool, workspaceState: WorkspaceState) async {
        let repositoryRoot = snapshot?.repositoryRoot
            ?? currentWorkingDirectory
            ?? change.absoluteURL.deletingLastPathComponent()

        do {
            let diffText = try await gitService.diff(for: change, staged: staged, repositoryRoot: repositoryRoot)
            selectedChange = change
            selectedDiffIsStaged = staged
            selectedDiffText = diffText
            workspaceState.selectedGitDiffPath = change.absoluteURL
            workspaceState.selectedGitDiffText = diffText
            workspaceState.selectedGitDiffTitle = change.relativePath
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func stage(_ change: GitFileChange) async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }
        await performMutation(successMessage: "已暂存 \(change.relativePath)") {
            try await gitService.stage(path: change.relativePath, repositoryRoot: repositoryRoot)
        }
    }

    func unstage(_ change: GitFileChange) async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }
        await performMutation(successMessage: "已取消暂存 \(change.relativePath)") {
            try await gitService.unstage(path: change.relativePath, repositoryRoot: repositoryRoot)
        }
    }

    func stageAll() async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }
        await performMutation(successMessage: "已暂存全部变更") {
            try await gitService.stageAll(repositoryRoot: repositoryRoot)
        }
    }

    func requestDiscard(_ change: GitFileChange) {
        pendingDangerousAction = .discard(change)
    }

    func requestClean(_ change: GitFileChange) {
        pendingDangerousAction = .clean(change)
    }

    func confirmPendingAction() async {
        guard let action = pendingDangerousAction,
              let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else {
            pendingDangerousAction = nil
            return
        }

        pendingDangerousAction = nil

        switch action {
        case .discard(let change):
            await performMutation(successMessage: "已丢弃 \(change.relativePath) 的改动") {
                try await gitService.discard(path: change.relativePath, repositoryRoot: repositoryRoot)
            }
        case .clean(let change):
            await performMutation(successMessage: "已删除未跟踪文件 \(change.relativePath)") {
                try await gitService.cleanUntracked(path: change.relativePath, repositoryRoot: repositoryRoot)
            }
        }
    }

    func commit() async {
        guard let repositoryRoot = snapshot?.repositoryRoot ?? currentWorkingDirectory else { return }
        let message = commitMessage

        do {
            try await gitService.commit(message: message, repositoryRoot: repositoryRoot)
            commitMessage = ""
            transientBanner = "提交成功"
            loadError = nil
            await refresh(for: repositoryRoot)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func performMutation(successMessage: String, operation: () async throws -> Void) async {
        guard let workingDirectory = currentWorkingDirectory ?? snapshot?.repositoryRoot else { return }
        do {
            try await operation()
            transientBanner = successMessage
            loadError = nil
            await refresh(for: workingDirectory)
        } catch {
            loadError = error.localizedDescription
        }
    }
}