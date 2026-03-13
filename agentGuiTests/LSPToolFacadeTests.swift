import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPToolFacadeTests {

    @Test func listServersIncludesBuiltInProfiles() throws {
        let settings = AppSettings.testFixture()
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: nil)

        let text = facade.listServers()

        #expect(text.contains("typescript-language-server"))
        #expect(text.contains("python-lsp"))
    }

    @Test func serverStatusReflectsRunningSession() async throws {
        let harness = LSPToolFacadeHarness()
        let manager = harness.makeManager()
        let settings = AppSettings.testFixture()
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: manager)

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")

        let text = facade.serverStatus(workspaceRoot: "/repo", serverID: "typescript-language-server")

        #expect(text.contains("running"))
        #expect(text.contains("typescript-language-server"))
    }

    @Test func serverStatusIncludesRecentRuntimeLogs() async throws {
        let harness = LSPToolFacadeHarness()
        let manager = harness.makeManager()
        let settings = AppSettings.testFixture()
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: manager)

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "python-lsp")
        harness.lastProcess?.standardErrorHandler?(Data("Python trace on stderr".utf8))
        await Task.yield()

        let text = facade.serverStatus(workspaceRoot: "/repo", serverID: "python-lsp")

        #expect(text.contains("Recent logs"))
        #expect(text.contains("Python trace on stderr"))
    }

    @Test func diagnosticsRendersPublishedMessages() async throws {
        let harness = LSPToolFacadeHarness()
        let manager = harness.makeManager()
        let settings = AppSettings.testFixture()
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: manager)

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        manager.publishDiagnostics(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            uri: "file:///repo/src/app.ts",
            diagnostics: [.init(message: "Type mismatch", severity: .error)]
        )

        let text = facade.diagnostics(workspaceRoot: "/repo", uri: "file:///repo/src/app.ts")

        #expect(text.contains("Type mismatch"))
        #expect(text.contains("error"))
    }

    @Test func definitionReturnsResolvedLocationText() async throws {
        let harness = LSPToolFacadeHarness()
        harness.responses["textDocument/definition"] = [
            [
                "uri": "file:///repo/src/definition.ts",
                "range": [
                    "start": ["line": 4, "character": 2],
                    "end": ["line": 4, "character": 9]
                ]
            ]
        ]
        let manager = harness.makeManager()
        let settings = AppSettings.testFixture()
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: manager)

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")

        let text = try await facade.definition(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            uri: "file:///repo/src/app.ts",
            line: 1,
            character: 3
        )

        #expect(text.contains("file:///repo/src/definition.ts"))
        #expect(text.contains("4:2"))
    }
}

@MainActor
private final class LSPToolFacadeHarness {
    var responses: [String: Any] = [:]
    private(set) var lastProcess: LSPToolFacadeManagedProcess?

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.testFixture()
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: {
                let transport = LSPJSONRPCTransport()
                let responseMap = self.responses
                transport.outgoingDataHandler = { data in
                    guard let payload = LSPToolFacadeHarness.decodePayload(data),
                          let id = payload["id"] as? String,
                          let method = payload["method"] as? String else {
                        return
                    }

                    if method == "initialize" {
                        let responseObject: [String: Any] = [
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
                        ]
                        let framed = try? transport.makeOutgoingData(jsonObject: responseObject)
                        if let framed {
                            _ = try? transport.receive(framed)
                        }
                        return
                    }

                    guard let result = responseMap[method] else {
                        return
                    }

                    let responseObject: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                    let framed = try? transport.makeOutgoingData(jsonObject: responseObject)
                    if let framed {
                        _ = try? transport.receive(framed)
                    }
                }
                return LSPClient(
                    transport: transport,
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: GenericLSPServerAdapter()
                )
            },
            makeSupervisor: {
                LSPProcessSupervisor(processLauncher: LSPToolFacadeProcessLauncher(onCreateProcess: { process in
                    self.lastProcess = process
                }))
            }
        )
    }

    private static func decodePayload(_ data: Data) -> [String: Any]? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let body = data.suffix(from: separator.upperBound)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class LSPToolFacadeProcessLauncher: LSPProcessLaunching {
    private let onCreateProcess: (LSPToolFacadeManagedProcess) -> Void

    init(onCreateProcess: @escaping (LSPToolFacadeManagedProcess) -> Void) {
        self.onCreateProcess = onCreateProcess
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        let process = LSPToolFacadeManagedProcess()
        onCreateProcess(process)
        return process
    }
}

private final class LSPToolFacadeManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 321
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?

    func start() throws {}

    func send(_ data: Data) throws {}

    func stop() {}
}