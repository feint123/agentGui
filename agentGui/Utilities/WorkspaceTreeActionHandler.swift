import Foundation

struct WorkspaceTreeSelectionSnapshot: Equatable {
    var selectedTreeNodeID: URL?
    var selectedFile: URL?
    var selectedGitDiffPath: URL?

    init(selectedTreeNodeID: URL?, selectedFile: URL?, selectedGitDiffPath: URL?) {
        self.selectedTreeNodeID = selectedTreeNodeID?.standardizedFileURL
        self.selectedFile = selectedFile?.standardizedFileURL
        self.selectedGitDiffPath = selectedGitDiffPath?.standardizedFileURL
    }
}

struct WorkspaceTreeActionHandler {

    func applyingRename(from originalURL: URL, to renamedURL: URL, selection: WorkspaceTreeSelectionSnapshot) -> WorkspaceTreeSelectionSnapshot {
        let updatedDiffPath: URL?
        if let selectedDiffPath = selection.selectedGitDiffPath,
           contains(originalURL, candidate: selectedDiffPath) {
            updatedDiffPath = nil
        } else {
            updatedDiffPath = selection.selectedGitDiffPath
        }

        return WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: remapSelectionURL(selection.selectedTreeNodeID, from: originalURL, to: renamedURL),
            selectedFile: remapSelectionURL(selection.selectedFile, from: originalURL, to: renamedURL),
            selectedGitDiffPath: updatedDiffPath
        )
    }

    func applyingDeletion(of deletedURL: URL, selection: WorkspaceTreeSelectionSnapshot) -> WorkspaceTreeSelectionSnapshot {
        WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: contains(deletedURL, candidate: selection.selectedTreeNodeID) ? nil : selection.selectedTreeNodeID,
            selectedFile: contains(deletedURL, candidate: selection.selectedFile) ? nil : selection.selectedFile,
            selectedGitDiffPath: contains(deletedURL, candidate: selection.selectedGitDiffPath) ? nil : selection.selectedGitDiffPath
        )
    }

    private func remapSelectionURL(_ candidate: URL?, from originalURL: URL, to renamedURL: URL) -> URL? {
        guard let candidate else { return nil }

        let originalPath = originalURL.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path

        if candidatePath == originalPath {
            return renamedURL.standardizedFileURL
        }
        guard candidatePath.hasPrefix(originalPath + "/") else {
            return candidate.standardizedFileURL
        }

        let suffix = String(candidatePath.dropFirst(originalPath.count))
        return URL(fileURLWithPath: renamedURL.path + suffix).standardizedFileURL
    }

    private func contains(_ containerURL: URL, candidate: URL?) -> Bool {
        guard let candidate else { return false }
        let containerPath = containerURL.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
    }
}