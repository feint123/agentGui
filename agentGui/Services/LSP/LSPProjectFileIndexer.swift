import Foundation

protocol LSPProjectFileIndexing {
    func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]]
}

struct LSPProjectFileIndexer: LSPProjectFileIndexing {
    func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]] {
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
            let pathComponents = fileURL.pathComponents
            if pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
                continue
            }
            if pathComponents.contains("node_modules") || pathComponents.contains(".build") || pathComponents.contains("build") {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            guard let languageID = languageID(for: fileURL.pathExtension.lowercased()) else {
                continue
            }

            for definition in definitions where definition.supportedLanguageIDs.contains(languageID) {
                filesByServerID[definition.id, default: []].append(fileURL.standardizedFileURL.path)
            }
        }

        return filesByServerID.mapValues { $0.sorted() }
    }

    private func languageID(for fileExtension: String) -> String? {
        switch fileExtension {
        case "ts":
            return "typescript"
        case "tsx":
            return "typescriptreact"
        case "js":
            return "javascript"
        case "jsx":
            return "javascriptreact"
        case "py":
            return "python"
        default:
            return nil
        }
    }
}