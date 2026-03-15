import Foundation
@testable import agentGui

@MainActor
final class SharedLSPServerManagerHarness {
    private let settings: AppSettings
    private(set) var stopCallCount = 0
    private(set) var documentLifecycleEvents: [String] = []
    private(set) var lastClientDocumentSnapshot: LSPDocumentSnapshot?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func makeManager() -> LSPServerManager {
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: {
                let client = LSPClient(
                    transport: LSPJSONRPCTransport(),
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: SharedHarnessLSPServerAdapter()
                )
                client.onDocumentLifecycleEvent = { [weak self] event, snapshot in
                    self?.documentLifecycleEvents.append(event)
                    self?.lastClientDocumentSnapshot = snapshot
                }
                return client
            },
            makeSupervisor: {
                LSPProcessSupervisor(
                    processLauncher: SharedHarnessProcessLauncher(onStop: { [weak self] in
                        self?.stopCallCount += 1
                    })
                )
            }
        )
    }
}

private struct SharedHarnessLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class SharedHarnessProcessLauncher: LSPProcessLaunching {
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        SharedHarnessManagedProcess(onStop: onStop)
    }
}

private final class SharedHarnessManagedProcess: LSPManagedProcess {
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