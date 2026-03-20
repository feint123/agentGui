import Foundation

struct WorkspaceTreeSelectionSnapshot: Equatable {
    var primarySelectionID: URL?
    var selectedTreeNodeIDs: Set<URL>
    var selectedFile: URL?
    var selectedGitDiffPath: URL?

    init(
        selectedTreeNodeID: URL?,
        selectedTreeNodeIDs: Set<URL> = [],
        selectedFile: URL?,
        selectedGitDiffPath: URL?
    ) {
        let standardizedPrimary = selectedTreeNodeID?.standardizedFileURL
        let standardizedSelections = Set(selectedTreeNodeIDs.map(\.standardizedFileURL))
        self.primarySelectionID = standardizedPrimary
        if let standardizedPrimary {
            self.selectedTreeNodeIDs = standardizedSelections.union([standardizedPrimary])
        } else {
            self.selectedTreeNodeIDs = standardizedSelections
        }
        self.selectedFile = selectedFile?.standardizedFileURL
        self.selectedGitDiffPath = selectedGitDiffPath?.standardizedFileURL
    }

    var selectedTreeNodeID: URL? {
        primarySelectionID
    }
}

struct WorkspaceTreeActionHandler {

    func applyingMove(from originalURLs: [URL], to movedURLs: [URL], selection: WorkspaceTreeSelectionSnapshot) -> WorkspaceTreeSelectionSnapshot {
        let mappings = moveMappings(from: originalURLs, to: movedURLs)
        return WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: remapSelectionURL(selection.primarySelectionID, with: mappings),
            selectedTreeNodeIDs: remapSelectionURLs(selection.selectedTreeNodeIDs, with: mappings),
            selectedFile: remapSelectionURL(selection.selectedFile, with: mappings),
            selectedGitDiffPath: remapSelectionURL(selection.selectedGitDiffPath, with: mappings)
        )
    }

    func applyingRename(from originalURL: URL, to renamedURL: URL, selection: WorkspaceTreeSelectionSnapshot) -> WorkspaceTreeSelectionSnapshot {
        let updatedDiffPath: URL?
        if let selectedDiffPath = selection.selectedGitDiffPath,
           contains(originalURL, candidate: selectedDiffPath) {
            updatedDiffPath = nil
        } else {
            updatedDiffPath = selection.selectedGitDiffPath
        }

        return WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: remapSelectionURL(selection.primarySelectionID, from: originalURL, to: renamedURL),
            selectedTreeNodeIDs: remapSelectionURLs(selection.selectedTreeNodeIDs, from: originalURL, to: renamedURL),
            selectedFile: remapSelectionURL(selection.selectedFile, from: originalURL, to: renamedURL),
            selectedGitDiffPath: updatedDiffPath
        )
    }

    func applyingDeletion(of deletedURL: URL, selection: WorkspaceTreeSelectionSnapshot) -> WorkspaceTreeSelectionSnapshot {
        WorkspaceTreeSelectionSnapshot(
            selectedTreeNodeID: contains(deletedURL, candidate: selection.primarySelectionID) ? nil : selection.primarySelectionID,
            selectedTreeNodeIDs: Set(selection.selectedTreeNodeIDs.filter { !contains(deletedURL, candidate: $0) }),
            selectedFile: contains(deletedURL, candidate: selection.selectedFile) ? nil : selection.selectedFile,
            selectedGitDiffPath: contains(deletedURL, candidate: selection.selectedGitDiffPath) ? nil : selection.selectedGitDiffPath
        )
    }

    private func remapSelectionURLs(_ candidates: Set<URL>, from originalURL: URL, to renamedURL: URL) -> Set<URL> {
        Set(candidates.compactMap { remapSelectionURL($0, from: originalURL, to: renamedURL) })
    }

    private func remapSelectionURLs(_ candidates: Set<URL>, with mappings: [(from: URL, to: URL)]) -> Set<URL> {
        Set(candidates.compactMap { remapSelectionURL($0, with: mappings) })
    }

    private func remapSelectionURL(_ candidate: URL?, with mappings: [(from: URL, to: URL)]) -> URL? {
        guard let candidate else { return nil }

        for mapping in mappings {
            let remapped = remapSelectionURL(candidate, from: mapping.from, to: mapping.to)
            if remapped != candidate.standardizedFileURL {
                return remapped
            }
        }

        return candidate.standardizedFileURL
    }

    private func moveMappings(from originalURLs: [URL], to movedURLs: [URL]) -> [(from: URL, to: URL)] {
        zip(originalURLs.map(\.standardizedFileURL), movedURLs.map(\.standardizedFileURL))
            .sorted { lhs, rhs in lhs.0.path.count > rhs.0.path.count }
            .map { (from: $0.0, to: $0.1) }
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