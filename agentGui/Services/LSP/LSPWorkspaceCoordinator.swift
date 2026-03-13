import Foundation

struct LSPWorkspaceBootstrapResult: Equatable, Sendable {
    let startedServerIDs: [String]
    let indexedFiles: [String: [String]]

    static let empty = LSPWorkspaceBootstrapResult(startedServerIDs: [], indexedFiles: [:])
}

@MainActor
final class LSPWorkspaceCoordinator {
    private let registry: LSPServerRegistry
    private let serverManager: LSPServerManager
    private let fileIndexer: any LSPProjectFileIndexing

    init(
        registry: LSPServerRegistry,
        serverManager: LSPServerManager,
        fileIndexer: any LSPProjectFileIndexing = LSPProjectFileIndexer()
    ) {
        self.registry = registry
        self.serverManager = serverManager
        self.fileIndexer = fileIndexer
    }

    func bootstrapWorkspace(
        workingDirectory: String,
        selectedFilePath: String?,
        settings: AppSettings
    ) async throws -> LSPWorkspaceBootstrapResult {
        guard settings.isLSPAutoStartEffective,
              !workingDirectory.isEmpty else {
            return .empty
        }

        var indexedFiles = fileIndexer.indexFiles(in: workingDirectory, registry: registry)
        if indexedFiles.isEmpty,
           let selectedFilePath,
           let binding = LSPWorkspaceResolver().resolve(
                filePath: selectedFilePath,
                workingDirectory: workingDirectory,
                registry: registry,
                settings: settings
           ) {
            indexedFiles[binding.serverID] = [selectedFilePath]
        }

        var startedServerIDs: [String] = []
        for serverID in indexedFiles.keys.sorted() {
            if let state = serverManager.state(for: workingDirectory, serverID: serverID) {
                switch state {
                case .crashed, .failedToLaunch, .stopped:
                    _ = try await serverManager.recoverSessionIfNeeded(workspaceRoot: workingDirectory, serverID: serverID)
                    startedServerIDs.append(serverID)
                case .idle, .starting, .running:
                    continue
                }
            }
            else {
                _ = try await serverManager.startSession(workspaceRoot: workingDirectory, serverID: serverID)
                startedServerIDs.append(serverID)
            }
        }

        return LSPWorkspaceBootstrapResult(
            startedServerIDs: startedServerIDs,
            indexedFiles: indexedFiles
        )
    }
}