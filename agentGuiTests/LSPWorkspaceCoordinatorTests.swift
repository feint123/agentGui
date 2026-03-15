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
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
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
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
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
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
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

    @Test func workspaceBootstrapPrewarmsIndexedFilesToPopulateProjectDiagnostics() async throws {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        harness.indexer.stubbed = [
            "typescript-language-server": [
                "/repo/src/app.ts",
                "/repo/src/feature.ts"
            ]
        ]
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer,
            fileLoader: harness.fileLoader.load
        )

        _ = try await coordinator.bootstrapWorkspace(
            workingDirectory: "/repo",
            selectedFilePath: nil,
            settings: settings
        )

        #expect(harness.fileLoader.loadedPaths == ["/repo/src/app.ts", "/repo/src/feature.ts"])
        #expect(harness.openedDocuments == [
            "file:///repo/src/app.ts",
            "file:///repo/src/feature.ts"
        ])
    }

    @Test func workspaceBootstrapPrewarmsSupportedInstalledServers() async throws {
        let settings = AppSettings.lspFixture(installedProviderIDs: [
            "gopls",
            "clangd"
        ])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        harness.indexer.stubbed = [
            "gopls": ["/repo/cmd/main.go"],
            "clangd": ["/repo/native/app.cpp"]
        ]
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer,
            fileLoader: harness.fileLoader.load
        )

        let result = try await coordinator.bootstrapWorkspace(
            workingDirectory: "/repo",
            selectedFilePath: nil,
            settings: settings
        )

        #expect(Set(result.startedServerIDs) == ["gopls", "clangd"])
        #expect(harness.fileLoader.loadedPaths.sorted() == [
            "/repo/cmd/main.go",
            "/repo/native/app.cpp"
        ])
        #expect(Set(harness.openedDocuments) == [
            "file:///repo/cmd/main.go",
            "file:///repo/native/app.cpp"
        ])
    }

    @Test func workspaceBootstrapIndexesFilesOffMainActor() async throws {
        let settings = AppSettings.testFixture()
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        let registry = try LSPServerRegistry(settings: settings)
        let harness = LSPWorkspaceCoordinatorHarness(settings: settings)
        let coordinator = LSPWorkspaceCoordinator(
            registry: registry,
            serverManager: harness.manager,
            fileIndexer: harness.indexer,
            fileLoader: harness.fileLoader.load
        )

        _ = try await coordinator.bootstrapWorkspace(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(harness.indexer.lastCallWasOnMainActor == false)
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
    let fileLoader = StubLSPWorkspaceFileLoader()
    private let processRecorder: WorkspaceCoordinatorProcessRecorder
    var openedDocuments: [String] { processRecorder.openedDocuments }

    init(settings: AppSettings) {
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()
        let processRecorder = WorkspaceCoordinatorProcessRecorder()
        self.processRecorder = processRecorder
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
                LSPProcessSupervisor(processLauncher: WorkspaceCoordinatorLauncher { process in
                    processRecorder.append(process)
                })
            }
        )
    }
}

private final class WorkspaceCoordinatorProcessRecorder {
    private(set) var processes: [WorkspaceCoordinatorManagedProcess] = []

    var openedDocuments: [String] {
        processes.flatMap(\.openedDocuments)
    }

    func append(_ process: WorkspaceCoordinatorManagedProcess) {
        processes.append(process)
    }
}

private final class StubLSPProjectFileIndexer: LSPProjectFileIndexing, @unchecked Sendable {
    var stubbed: [String: [String]] = [:]
    private(set) var lastCallWasOnMainActor = true

    func indexFiles(in workspaceRoot: String, registry: LSPServerRegistry) -> [String: [String]] {
        lastCallWasOnMainActor = Thread.isMainThread
        if !stubbed.isEmpty {
            return stubbed
        }
        return LSPProjectFileIndexer().indexFiles(in: workspaceRoot, registry: registry)
    }
}

private final class StubLSPWorkspaceFileLoader {
    var contentsByPath: [String: String] = [
        "/repo/src/app.ts": "const broken: string = 42\n",
        "/repo/src/feature.ts": "export const feature = true\n",
        "/repo/cmd/main.go": "package main\nfunc main() {}\n",
        "/repo/native/app.cpp": "int main() { return 0; }\n"
    ]
    private(set) var loadedPaths: [String] = []

    func load(path: String) async -> String? {
        loadedPaths.append(path)
        return contentsByPath[path]
    }
}

private struct WorkspaceCoordinatorAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class WorkspaceCoordinatorLauncher: LSPProcessLaunching {
    private let onProcessCreated: (WorkspaceCoordinatorManagedProcess) -> Void

    init(onProcessCreated: @escaping (WorkspaceCoordinatorManagedProcess) -> Void = { _ in }) {
        self.onProcessCreated = onProcessCreated
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        let process = WorkspaceCoordinatorManagedProcess()
        onProcessCreated(process)
        return process
    }
}

private final class WorkspaceCoordinatorManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 606
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    private(set) var openedDocuments: [String] = []

    func start() throws {}

    func send(_ data: Data) throws {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return
        }
        let body = data.suffix(from: separator.upperBound)
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return
        }

        if payload["id"] == nil,
           payload["method"] as? String == "textDocument/didOpen",
           let textDocument = payload["params"] as? [String: Any],
           let document = textDocument["textDocument"] as? [String: Any],
           let uri = document["uri"] as? String {
            openedDocuments.append(uri)
            return
        }

        guard let id = payload["id"] else {
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