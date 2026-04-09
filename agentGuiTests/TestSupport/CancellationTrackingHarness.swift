import Foundation
@testable import agentGui

/// Harness that tracks $/cancelRequest notifications sent by the transport.
///
/// Intercepts the transport's outgoingDataHandler to record $/cancelRequest notifications
/// and auto-replies to hover/definition/references with a delayed response (to allow
/// cancellation to happen while the request is in-flight).
@MainActor
final class CancellationTrackingHarness {
    private(set) var cancelRequestIDs: [String] = []

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["python-lsp"])
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: { [weak self] in
                let transport = LSPJSONRPCTransport()
                let client = LSPClient(
                    transport: transport,
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: CancellationHarnessAdapter()
                )

                // Intercept outgoing data to track $/cancelRequest notifications
                // and auto-reply to requests with a delay (simulates slow server).
                transport.outgoingDataHandler = { [weak self, weak transport] data in
                    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return }
                    let body = data.suffix(from: separator.upperBound)
                    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }

                    // Track $/cancelRequest notifications
                    if json["method"] as? String == "$/cancelRequest",
                       json["id"] == nil,
                       let params = json["params"] as? [String: Any],
                       let cancelledID = params["id"] as? String {
                        Task { @MainActor in
                            self?.cancelRequestIDs.append(cancelledID)
                        }
                        return
                    }

                    // Skip notifications (no "id" field means it's a notification, not a request)
                    guard let requestIDValue = json["id"],
                          let method = json["method"] as? String else { return }

                    let requestID: String
                    if let str = requestIDValue as? String {
                        requestID = str
                    } else if let num = requestIDValue as? NSNumber {
                        requestID = num.stringValue
                    } else {
                        return
                    }

                    // Auto-reply with a delay for hover/definition requests (to allow cancellation in-flight)
                    let delay: UInt64 = (method == "textDocument/hover" || method == "textDocument/definition") ? 200_000_000 : 0
                    Task { [weak transport] in
                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: delay)
                        }
                        guard let transport else { return }

                        let result: Any = CancellationHarnessAdapter.responseResult(for: method)
                        let response: [String: Any] = [
                            "jsonrpc": "2.0",
                            "id": requestID,
                            "result": result
                        ]
                        guard let responseData = try? JSONSerialization.data(withJSONObject: response) else { return }
                        var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
                        framed.append(responseData)
                        _ = try? transport.receive(framed)
                    }
                }
                return client
            },
            makeSupervisor: {
                LSPProcessSupervisor(processLauncher: NoOpProcessLauncherForCancellationHarness())
            }
        )
    }
}

private struct CancellationHarnessAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }

    static func responseResult(for method: String) -> Any {
        switch method {
        case "initialize":
            return [
                "capabilities": [
                    "hoverProvider": true,
                    "definitionProvider": true,
                    "referencesProvider": true
                ]
            ]
        case "textDocument/hover":
            return [
                "contents": [
                    "kind": "markdown",
                    "value": "Demo hover"
                ]
            ]
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
                ]
            ]
        default:
            return NSNull()
        }
    }
}

private final class NoOpProcessLauncherForCancellationHarness: LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        NoOpManagedProcessForCancellationHarness()
    }
}

private final class NoOpManagedProcessForCancellationHarness: LSPManagedProcess {
    let processIdentifier: Int32 = 100
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    func start() throws {}
    func send(_ data: Data) throws {}
    func stop() {}
}
