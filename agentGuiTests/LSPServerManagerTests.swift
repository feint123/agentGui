import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPServerManagerTests {

    @Test func startSessionReusesExistingSessionForSameWorkspaceAndServer() async throws {
        let harness = LSPServerManagerHarness()
        let manager = harness.makeManager()

        let first = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        let second = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")

        #expect(first == second)
        #expect(manager.activeSessionCount == 1)
    }

    @Test func startSessionDoesNotReuseAcrossDifferentServers() async throws {
        let harness = LSPServerManagerHarness()
        let manager = harness.makeManager()

        let typescript = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        let python = try await manager.startSession(workspaceRoot: "/repo", serverID: "python-lsp")

        #expect(typescript != python)
        #expect(manager.activeSessionCount == 2)
    }

    @Test func startSessionCachesCapabilitiesFromInitialize() async throws {
        let harness = LSPServerManagerHarness()
        let manager = harness.makeManager()

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")

        let capabilities = try #require(
            manager.capabilities(for: "/repo", serverID: "typescript-language-server")
        )

        #expect(capabilities.supportsDefinition == true)
        #expect(capabilities.supportsWorkspaceSymbols == true)
    }

    @Test func publishDiagnosticsWritesToDiagnosticsStore() async throws {
        let harness = LSPServerManagerHarness()
        let manager = harness.makeManager()

        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        manager.publishDiagnostics(
            workspaceRoot: "/repo",
            serverID: "typescript-language-server",
            uri: "file:///repo/src/app.ts",
            diagnostics: [
                .init(message: "Type mismatch", severity: .error)
            ]
        )

        let snapshot = try #require(
            manager.diagnosticsStore.snapshot(for: "/repo", uri: "file:///repo/src/app.ts")
        )
        #expect(snapshot.diagnostics.count == 1)
        #expect(snapshot.diagnostics.first?.message == "Type mismatch")
    }

    @Test func restartServerStopsExistingSessionAndCreatesNewOne() async throws {
        let harness = LSPServerManagerHarness()
        let manager = harness.makeManager()

        let first = try await manager.startSession(workspaceRoot: "/repo", serverID: "typescript-language-server")
        let restarted = try await manager.restartServer(workspaceRoot: "/repo", serverID: "typescript-language-server")

        #expect(first != restarted)
        #expect(harness.stopCallCount == 1)
        #expect(manager.activeSessionCount == 1)
    }
}

@MainActor
private final class LSPServerManagerHarness {
    private(set) var stopCallCount = 0

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.testFixture()
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
                    adapter: FakeLSPServerAdapter()
                )
            },
            makeSupervisor: {
                LSPProcessSupervisor(
                    processLauncher: FakeManagerProcessLauncher(onStop: { [weak self] in
                        self?.stopCallCount += 1
                    })
                )
            }
        )
    }
}

private struct FakeLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class FakeManagerProcessLauncher: LSPProcessLaunching {
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        FakeManagerManagedProcess(onStop: onStop)
    }
}

private final class FakeManagerManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 99
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

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

    func stop() {
        onStop()
    }
}