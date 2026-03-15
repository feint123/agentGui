import Foundation

protocol LSPProjectFileIndexing: Sendable {
    nonisolated func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]]
}

struct LSPProjectFileIndexer: LSPProjectFileIndexing {
    private static let excludedDirectoryNames: Set<String> = [
        ".build",
        ".tox",
        "__pypackages__",
        "build",
        "dist-packages",
        "env",
        "node_modules",
        "site-packages",
        "venv"
    ]

    nonisolated func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]] {
        let workspaceURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return [:]
        }

        let definitions = registry.allDefinitions().filter { $0.adapterKind == .generic }
        var filesByServerID: [String: [String]] = [:]

        for case let fileURL as URL in enumerator {
            let pathComponents = fileURL.pathComponents.map { $0.lowercased() }
            if pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
                continue
            }
            if pathComponents.contains(where: Self.excludedDirectoryNames.contains) {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            guard let languageID = LSPFileLanguageMapper.languageID(forExtension: fileURL.pathExtension.lowercased()) else {
                continue
            }

            for definition in definitions where definition.supportedLanguageIDs.contains(languageID) {
                filesByServerID[definition.id, default: []].append(fileURL.standardizedFileURL.path)
            }
        }

        return filesByServerID.mapValues { $0.sorted() }
    }
}