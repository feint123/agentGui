import Foundation
import Testing
@testable import agentGui

@MainActor
struct ClaudeServiceWorkspaceContextTests {

    @Test func ensureLSPServerStartedAutoStartsMatchingSessionWhenEnabled() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        service.lspServerManager = harness.makeManager(settings: settings)

        let didStart = try await service.ensureLSPServerStartedIfNeeded(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            settings: settings
        )

        #expect(didStart == true)
        #expect(service.lspServerManager?.state(for: "/repo", serverID: "typescript-language-server")?.summaryText.contains("running") == true)
    }

    @Test func ensureWorkspaceLSPStateBootstrapsProjectWithoutSelectedFile() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        service.lspServerManager = harness.makeManager(settings: settings)

        let workspaceRoot = try makeWorkspace(files: [
            "src/app.ts": "const answer: number = 42\n",
            "tools/script.py": "print('hi')\n"
        ])

        let result = try await service.ensureWorkspaceLSPState(
            workingDirectory: workspaceRoot.path,
            selectedFilePath: nil,
            settings: settings
        )

        #expect(Set(result.startedServerIDs) == ["typescript-language-server", "python-lsp"])
    }

    @Test func ensureWorkspaceLSPStateUsesSelectedFileAsFallback() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        service.lspServerManager = harness.makeManager(settings: settings)

        let result = try await service.ensureWorkspaceLSPState(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(result.startedServerIDs == ["typescript-language-server"])
        #expect(result.indexedFiles["typescript-language-server"] == ["/repo/src/app.ts"])
    }

    @Test func ensureWorkspaceLSPStateRestartsCrashedSession() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        service.lspServerManager = harness.makeManager(settings: settings)

        _ = try await service.lspServerManager?.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        harness.lastProcess?.terminationHandler?(9)
        await Task.yield()

        let result = try await service.ensureWorkspaceLSPState(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(result.startedServerIDs == ["typescript-language-server"])
        #expect(service.lspServerManager?.state(for: "/repo", serverID: "typescript-language-server")?.summaryText.contains("running") == true)
    }

    @Test func workspaceContextCarriesSelectedFileAndSelection() {
        let service = ClaudeService()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])

        let context = service.makeWorkflowWorkspaceContextForTests(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            selectedText: "const answer = 42",
            availableSkills: [WorkflowSkillInfo(name: "web-search", description: "Search the web")],
            settings: settings
        )

        #expect(context.workingDirectory == "/repo")
        #expect(context.selectedFilePath == "/repo/src/app.ts")
        #expect(context.selectedText == "const answer = 42")
        #expect(context.availableSkills.map(\.name) == ["web-search"])
        #expect(context.lspServerID == nil)
    }

    @Test func workspaceContextIncludesLSPServerAndDiagnosticsSummaryWhenAvailable() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        service.lspServerManager = harness.makeManager(settings: settings)

        _ = try await service.lspServerManager?.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        service.lspServerManager?.publishDiagnostics(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            uri: "file:///repo/src/app.ts",
            diagnostics: [
                .init(message: "Type mismatch", severity: .error),
                .init(message: "Unused variable", severity: .warning)
            ]
        )

        let context = service.makeWorkflowWorkspaceContextForTests(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            selectedText: nil,
            availableSkills: [],
            settings: settings
        )

        #expect(context.lspServerID == "typescript-language-server")
        #expect(context.lspServerStateSummary?.contains("running") == true)
        #expect(context.lspDiagnosticsSummary == "2 total [error=1, warning=1]")
    }

    @Test func workspacePanelStatusShowsDisabledWhenLSPToolsAreOff() {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()

        let status = service.makeWorkspacePanelLSPStatusForTests(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(status.stateText == "已禁用")
        #expect(status.serverID == nil)
        #expect(status.errorCount == 0)
        #expect(status.warningCount == 0)
    }

    @Test func workspacePanelStatusShowsRunningStateAndDiagnosticCounts() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let settings = AppSettings.lspFixture(installedProviderIDs: ["typescript-language-server"])
        settings.enableLSPTools = true
        service.lspServerManager = harness.makeManager(settings: settings)

        _ = try await service.lspServerManager?.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        service.lspServerManager?.publishDiagnostics(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            uri: "file:///repo/src/app.ts",
            diagnostics: [
                .init(message: "Type mismatch", severity: .error),
                .init(message: "Unused variable", severity: .warning),
                .init(message: "Another warning", severity: .warning)
            ]
        )

        let status = service.makeWorkspacePanelLSPStatusForTests(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/src/app.ts",
            settings: settings
        )

        #expect(status.serverID == "typescript-language-server")
        #expect(status.selectedFileName == "app.ts")
        #expect(status.stateText == "运行中")
        #expect(status.errorCount == 1)
        #expect(status.warningCount == 2)
    }

    @Test func workspacePanelStatusShowsProviderNotInstalledWhenCatalogMatchesFile() {
        let service = ClaudeService()
        let settings = AppSettings.testFixture()
        settings.enableLSPTools = true

        let status = service.makeWorkspacePanelLSPStatusForTests(
            workingDirectory: "/repo",
            selectedFilePath: "/repo/main.go",
            settings: settings
        )

        #expect(status.serverID == "gopls")
        #expect(status.stateText == "未安装")
    }

    @Test func ensureWorkspaceLSPStateRefreshesExistingManagerRegistryForNewInstalledProviders() async throws {
        let service = ClaudeService()
        let harness = ClaudeServiceWorkspaceContextHarness()
        let initialSettings = AppSettings.testFixture()
        service.lspServerManager = harness.makeManager(settings: initialSettings)

        let settings = AppSettings.lspFixture(installedProviderIDs: ["gopls"])
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true

        let workspaceRoot = try makeWorkspace(files: [
            "cmd/main.go": "package main\nfunc main() {}\n"
        ])

        let result = try await service.ensureWorkspaceLSPState(
            workingDirectory: workspaceRoot.path,
            selectedFilePath: nil,
            settings: settings
        )

        #expect(result.startedServerIDs == ["gopls"])
        #expect(service.lspServerManager?.state(for: workspaceRoot.path, serverID: "gopls")?.summaryText.contains("running") == true)
    }
}

@MainActor
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

@MainActor
private final class ClaudeServiceWorkspaceContextHarness {
    private(set) var lastProcess: ClaudeServiceWorkspaceContextProcess?

    func makeManager(settings: AppSettings) -> LSPServerManager {
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: {
                LSPClient(
                    transport: LSPJSONRPCTransport(),
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: ClaudeServiceWorkspaceContextAdapter()
                )
            },
            makeSupervisor: {
                LSPProcessSupervisor(processLauncher: ClaudeServiceWorkspaceContextLauncher(onCreate: { [weak self] process in
                    self?.lastProcess = process
                }))
            }
        )
    }
}

private struct ClaudeServiceWorkspaceContextAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class ClaudeServiceWorkspaceContextLauncher: LSPProcessLaunching {
    private let onCreate: (ClaudeServiceWorkspaceContextProcess) -> Void

    init(onCreate: @escaping (ClaudeServiceWorkspaceContextProcess) -> Void) {
        self.onCreate = onCreate
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        let process = ClaudeServiceWorkspaceContextProcess()
        onCreate(process)
        return process
    }
}

private final class ClaudeServiceWorkspaceContextProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 777
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