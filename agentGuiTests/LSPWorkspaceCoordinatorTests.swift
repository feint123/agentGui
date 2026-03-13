import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPWorkspaceCoordinatorTests {

    @Test func workspaceBootstrapStartsMatchingServersWithoutSelectedFile() async throws {
        let workspaceRoot = try makeWorkspace(files: [
            "src/app.ts": "const answer: number = 42\n",
            "tools/script.py": "print('hi')\n"
        ])
        let settings = AppSettings.testFixture()
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer
        )

        let result = try await coordinator.bootstrapWorkspace(
            workingDirectory: workspaceRoot.path,
            selectedFilePath: nil,
            settings: settings
        )

        #expect(Set(result.startedServerIDs) == ["typescript-language-server", "python-lsp"])
        #expect(result.indexedFiles["typescript-language-server"]?.count == 1)
        #expect(result.indexedFiles["python-lsp"]?.count == 1)
    }

    @Test func workspaceBootstrapAvoidsDuplicateStartsForSameServer() async throws {
        let settings = AppSettings.testFixture()
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        harness.indexer.stubbed = [
            "typescript-language-server": [
                "/repo/src/app.ts",
                "/repo/src/view.tsx"
            ]
        ]
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer
        )

        let result = try await coordinator.bootstrapWorkspace(
            workingDirectory: "/repo",
            selectedFilePath: nil,
            settings: settings
        )

        #expect(result.startedServerIDs == ["typescript-language-server"])
    }

    @Test func workspaceBootstrapUsesSelectedFileWhenWorkspaceIndexIsEmpty() async throws {
        let settings = AppSettings.testFixture()
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        harness.indexer.stubbed = [:]
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer
        )

        let result = try await coordinator.bootstrapWorkspace(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(result.startedServerIDs == ["typescript-language-server"])
        #expect(result.indexedFiles["typescript-language-server"] == ["/repo/src/app.ts"])
    }

    private func makeWorkspace(files: [String: String]) throws -> URL {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        for (relativePath, contents) in files {
            let fileURL = workspaceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return workspaceRoot
    }
}

@MainActor
private final class LSPWorkspaceCoordinatorHarness {
    let manager: LSPServerManager
    let indexer = StubLSPProjectFileIndexer()

    init(settings: AppSettings) {
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()
        manager = LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: {
                LSPClient(
                    transport: LSPJSONRPCTransport(),
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: WorkspaceCoordinatorAdapter()
                )
            },
            makeSupervisor: {
                LSPProcessSupervisor(processLauncher: WorkspaceCoordinatorLauncher())
            }
        )
    }
}

private final class StubLSPProjectFileIndexer: LSPProjectFileIndexing {
    var stubbed: [String: [String]] = [:]

    func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]] {
        if !stubbed.isEmpty {
            return stubbed
        }
        return LSPProjectFileIndexer().indexFiles(in: workspaceRoot, registry: registry)
    }
}

private struct WorkspaceCoordinatorAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class WorkspaceCoordinatorLauncher: LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        WorkspaceCoordinatorManagedProcess()
    }
}

private final class WorkspaceCoordinatorManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 606
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?

    func start() throws {}

    func send(_ data: Data) throws {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return
        }
        let body = data.suffix(from: separator.upperBound)
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = payload["id"] else {
            return
        }

        let responseBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "capabilities": [
                    "definitionProvider": true,
                    "referencesProvider": true,
                    "hoverProvider": true,
                    "documentSymbolProvider": true,
                    "workspaceSymbolProvider": true
                ]
            ]
        ])
        var framed = Data("Content-Length: \(responseBody.count)\r\n\r\n".utf8)
        framed.append(responseBody)
        standardOutputHandler?(framed)
    }

    func stop() {}
}