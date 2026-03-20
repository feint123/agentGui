import Foundation

struct WorkspaceTreeDropPlan: Equatable {
    let draggedURLs: [URL]
    let destinationDirectory: URL
}

struct WorkspaceTreeDropCoordinator {
    func proposal(for draggedURLs: Set<URL>, destination: FileNode?, rootDirectory: URL?) -> WorkspaceTreeDropPlan? {
        guard let destinationDirectory = resolvedDestinationDirectory(for: destination, rootDirectory: rootDirectory) else {
            return nil
        }
        let normalizedSources = collapseNestedSources(in: draggedURLs)
            .filter {
                normalizedDirectoryPath(for: $0.deletingLastPathComponent()) != normalizedDirectoryPath(for: destinationDirectory)
            }

        guard !normalizedSources.isEmpty else { return nil }
        guard normalizedSources.allSatisfy({ isValidDestination($0, destinationDirectory: destinationDirectory) }) else {
            return nil
        }

        return WorkspaceTreeDropPlan(
            draggedURLs: normalizedSources,
            destinationDirectory: destinationDirectory
        )
    }

    private func resolvedDestinationDirectory(for node: FileNode?, rootDirectory: URL?) -> URL? {
        guard let node else {
            return rootDirectory?.standardizedFileURL
        }

        if node.isDirectory {
            return node.id.standardizedFileURL
        }
        return node.id.deletingLastPathComponent().standardizedFileURL
    }

    private func normalizedDirectoryPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func collapseNestedSources(in draggedURLs: Set<URL>) -> [URL] {
        let normalized = Array(Set(draggedURLs.map(\.standardizedFileURL)))
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        var collapsed: [URL] = []
        for candidate in normalized {
            let isContainedByExistingParent = collapsed.contains { existing in
                candidate.path == existing.path || candidate.path.hasPrefix(existing.path + "/")
            }
            if !isContainedByExistingParent {
                collapsed.append(candidate)
            }
        }
        return collapsed
    }

    private func isValidDestination(_ source: URL, destinationDirectory: URL) -> Bool {
        let standardizedSource = source.standardizedFileURL
        let sourcePath = standardizedSource.path
        let destinationPath = destinationDirectory.path

        if destinationPath == sourcePath {
            return false
        }

        return !destinationPath.hasPrefix(sourcePath + "/")
    }
}