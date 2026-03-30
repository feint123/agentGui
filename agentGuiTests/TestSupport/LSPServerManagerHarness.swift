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
            "result": responseResult(for: payload)
        ])
        var framed = Data("Content-Length: \(responseBody.count)\r\n\r\n".utf8)
        framed.append(responseBody)
        standardOutputHandler?(framed)
    }

    private func responseResult(for payload: [String: Any]) -> Any {
        switch payload["method"] as? String {
        case "initialize":
            return [
                "capabilities": [
                    "definitionProvider": true,
                    "referencesProvider": true,
                    "hoverProvider": true,
                    "documentSymbolProvider": true,
                    "workspaceSymbolProvider": true
                ]
            ]
        case "textDocument/documentSymbol":
            let uri = ((payload["params"] as? [String: Any])?["textDocument"] as? [String: Any])?["uri"] as? String ?? ""
            return documentSymbolsResult(for: uri)
        case "textDocument/definition":
            return [
                "uri": "file:///tmp/Sample.py",
                "range": [
                    "start": ["line": 0, "character": 0],
                    "end": ["line": 0, "character": 4]
                ]
            ]
        case "textDocument/references":
            return [
                [
                    "uri": "file:///tmp/Sample.py",
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 4]
                    ]
                ],
                [
                    "uri": "file:///tmp/Other.py",
                    "range": [
                        "start": ["line": 4, "character": 2],
                        "end": ["line": 4, "character": 6]
                    ]
                ]
            ]
        case "textDocument/hover":
            return [
                "contents": [
                    "kind": "markdown",
                    "value": "Demo hover"
                ]
            ]
        default:
            return NSNull()
        }
    }

    private func documentSymbolsResult(for uri: String) -> Any {
        if uri.hasSuffix("FlatSample.py") {
            return [
                [
                    "name": "FlatDemo",
                    "kind": 5,
                    "location": [
                        "uri": uri,
                        "range": [
                            "start": ["line": 2, "character": 0],
                            "end": ["line": 6, "character": 0]
                        ]
                    ],
                    "containerName": "Module"
                ],
                [
                    "name": "helper",
                    "kind": 12,
                    "location": [
                        "uri": uri,
                        "range": [
                            "start": ["line": 8, "character": 4],
                            "end": ["line": 9, "character": 1]
                        ]
                    ],
                    "containerName": "FlatDemo"
                ]
            ]
        }

        return [
            [
                "name": "Demo",
                "detail": "class",
                "kind": 5,
                "selectionRange": [
                    "start": ["line": 0, "character": 0],
                    "end": ["line": 4, "character": 0]
                ],
                "children": [
                    [
                        "name": "inner",
                        "detail": "func",
                        "kind": 12,
                        "selectionRange": [
                            "start": ["line": 1, "character": 4],
                            "end": ["line": 2, "character": 0]
                        ],
                        "children": []
                    ]
                ]
            ]
        ]
    }

    func stop() {
        onStop()
    }
}