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
    private let fileLoader: @Sendable (String) async -> String?

    init(
        registry: LSPServerRegistry,
        serverManager: LSPServerManager,
        fileIndexer: any LSPProjectFileIndexing,
        fileLoader: (@Sendable (String) async -> String?)? = nil
    ) {
        self.registry = registry
        self.serverManager = serverManager
        self.fileIndexer = fileIndexer
        self.fileLoader = fileLoader ?? { path in
            await LSPWorkspaceCoordinator.loadFileContents(path: path)
        }
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

        var indexedFiles = await indexWorkspaceFiles(in: workingDirectory)
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

        await prewarmDiagnosticsIfNeeded(
            workspaceRoot: workingDirectory,
            indexedFiles: indexedFiles,
            startedServerIDs: startedServerIDs
        )

        return LSPWorkspaceBootstrapResult(
            startedServerIDs: startedServerIDs,
            indexedFiles: indexedFiles
        )
    }

    private func indexWorkspaceFiles(in workingDirectory: String) async -> [String: [String]] {
        let registry = registry
        let fileIndexer = fileIndexer
        return await Task.detached(priority: .utility) {
            fileIndexer.indexFiles(in: workingDirectory, registry: registry)
        }.value
    }

    private func prewarmDiagnosticsIfNeeded(
        workspaceRoot: String,
        indexedFiles: [String: [String]],
        startedServerIDs: [String]
    ) async {
        let serverIDsNeedingPrewarm = Set(startedServerIDs)
        guard !serverIDsNeedingPrewarm.isEmpty else { return }

        for serverID in serverIDsNeedingPrewarm.sorted() {
            for filePath in indexedFiles[serverID] ?? [] {
                guard let languageID = Self.languageID(for: filePath),
                      let text = await fileLoader(filePath) else {
                    continue
                }

                serverManager.syncDocument(
                    workspaceRoot: workspaceRoot,
                    serverID: serverID,
                    uri: URL(fileURLWithPath: filePath).absoluteString,
                    languageID: languageID,
                    text: text
                )
            }
        }
    }

    private static func loadFileContents(path: String) async -> String? {
        await Task.detached(priority: .utility) {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return text
            }
            return try? String(contentsOfFile: path, encoding: .isoLatin1)
        }.value
    }

    private static func languageID(for filePath: String) -> String? {
        LSPFileLanguageMapper.languageID(for: filePath)
    }
}