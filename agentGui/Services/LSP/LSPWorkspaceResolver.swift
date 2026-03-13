import Foundation

@MainActor
final class LSPWorkspaceResolver {
    struct ManualWorkspaceBinding: Codable, Hashable, Sendable {
        let workspaceRoot: String
        let serverID: String
    }

    enum ResolutionStatus: Equatable {
        case matched(serverID: String, isManual: Bool)
        case unresolved(reason: String)
    }

    struct ResolutionSnapshot: Equatable {
        let filePath: String
        let workingDirectory: String
        let status: ResolutionStatus
    }

    private(set) var lastResolution: ResolutionSnapshot?

    func resolve(
        filePath: String,
        workingDirectory: String,
        registry: LSPServerRegistry,
        settings: AppSettings
    ) -> LSPWorkspaceBinding? {
        if let manualBinding = manualBinding(for: workingDirectory, settings: settings) {
            let binding = LSPWorkspaceBinding(
                workspaceRoot: workingDirectory,
                serverID: manualBinding.serverID,
                languageID: languageID(for: filePath),
                isManual: true
            )
            lastResolution = ResolutionSnapshot(
                filePath: filePath,
                workingDirectory: workingDirectory,
                status: .matched(serverID: binding.serverID, isManual: true)
            )
            return binding
        }

        guard let languageID = languageID(for: filePath) else {
            lastResolution = ResolutionSnapshot(
                filePath: filePath,
                workingDirectory: workingDirectory,
                status: .unresolved(reason: "No LSP server profile matched file path")
            )
            return nil
        }

        guard let definition = registry.allDefinitions().first(where: { $0.supportedLanguageIDs.contains(languageID) }) else {
            lastResolution = ResolutionSnapshot(
                filePath: filePath,
                workingDirectory: workingDirectory,
                status: .unresolved(reason: "No LSP server profile matched file path")
            )
            return nil
        }

        let binding = LSPWorkspaceBinding(
            workspaceRoot: workingDirectory,
            serverID: definition.id,
            languageID: languageID,
            isManual: false
        )
        lastResolution = ResolutionSnapshot(
            filePath: filePath,
            workingDirectory: workingDirectory,
            status: .matched(serverID: binding.serverID, isManual: false)
        )
        return binding
    }

    private func manualBinding(for workingDirectory: String, settings: AppSettings) -> ManualWorkspaceBinding? {
        let trimmed = settings.lspManualWorkspaceBindingsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let bindings = try? JSONDecoder().decode([ManualWorkspaceBinding].self, from: data) else {
            return nil
        }

        return bindings.first(where: { $0.workspaceRoot == workingDirectory })
    }

    private func languageID(for filePath: String) -> String? {
        switch URL(fileURLWithPath: filePath).pathExtension.lowercased() {
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
