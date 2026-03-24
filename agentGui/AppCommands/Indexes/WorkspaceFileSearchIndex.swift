import Foundation

struct WorkspaceFileSearchResult: Identifiable {
    let fileURL: URL
    let relativePath: String

    var id: String {
        fileURL.path
    }
}

struct WorkspaceFileSearchIndex {
    func search(query: String, rootURL: URL, limit: Int = 50) throws -> [WorkspaceFileSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let fileManager = FileManager.default
        let rootPath = rootURL.standardizedFileURL.path
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var matches: [WorkspaceFileSearchResult] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let standardizedURL = fileURL.standardizedFileURL
            let path = standardizedURL.path
            guard path.hasPrefix(rootPath) else { continue }

            let relativePath = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard relativePath.localizedStandardContains(trimmedQuery) else { continue }

            matches.append(WorkspaceFileSearchResult(fileURL: standardizedURL, relativePath: relativePath))
            if matches.count >= limit {
                break
            }
        }

        return matches.sorted {
            let lhsNameMatch = URL(fileURLWithPath: $0.relativePath).lastPathComponent.localizedStandardContains(trimmedQuery)
            let rhsNameMatch = URL(fileURLWithPath: $1.relativePath).lastPathComponent.localizedStandardContains(trimmedQuery)

            if lhsNameMatch != rhsNameMatch {
                return lhsNameMatch && !rhsNameMatch
            }

            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}