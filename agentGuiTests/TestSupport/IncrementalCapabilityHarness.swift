import Foundation
@testable import agentGui

/// Test harness for Feature L-2 coordinator tests.
/// Captures the `range` field from the last outgoing `textDocument/didChange` message.
/// Works by inspecting all data in `send()` - does NOT set `outgoingDataHandler`
/// so `LSPClient.attach` wires transport → process normally.
@MainActor
final class IncrementalCapabilityHarness {
    private(set) var lastClientDocumentSnapshot: LSPDocumentSnapshot?
    /// Non-nil after a didChange with a `range` field is sent; nil after a full-sync didChange.
    private(set) var lastIncrementalChangeRange: [String: Any]?
    private(set) var lastDidChangeSeen = false

    // Called from the process send handler (may be on any thread, but tests are @MainActor)
    fileprivate func recordDidChange(range: [String: Any]?) {
        lastDidChangeSeen = true
        lastIncrementalChangeRange = range
    }

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["python-lsp"])
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: { [weak self] in
                let client = LSPClient(
                    transport: LSPJSONRPCTransport(),
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: IncrementalHarnessAdapter()
                )
                // Do NOT set outgoingDataHandler here — let attach() wire it to the process.
                client.onDocumentLifecycleEvent = { [weak self] _, snapshot in
                    self?.lastClientDocumentSnapshot = snapshot
                }
                return client
            },
            makeSupervisor: { [weak self] in
                LSPProcessSupervisor(
                    processLauncher: IncrementalHarnessProcessLauncher(harness: self)
                )
            }
        )
    }
}

// MARK: - Adapter

private struct IncrementalHarnessAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        var hints = LSPServerCapabilityHints.readOnlySemanticDefaults
        hints.syncKind = .incremental
        return hints
    }
}

// MARK: - Process Launcher

private final class IncrementalHarnessProcessLauncher: LSPProcessLaunching {
    weak var harness: IncrementalCapabilityHarness?
    init(harness: IncrementalCapabilityHarness?) {
        self.harness = harness
    }
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        IncrementalHarnessManagedProcess(harness: harness)
    }
}

// MARK: - Managed Process

private final class IncrementalHarnessManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 77
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    weak var harness: IncrementalCapabilityHarness?

    init(harness: IncrementalCapabilityHarness?) {
        self.harness = harness
    }

    func start() throws {}

    func send(_ data: Data) throws {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return }
        let body = data.suffix(from: separator.upperBound)
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let method = payload["method"] as? String

        // Capture textDocument/didChange (notifications have no id)
        if method == "textDocument/didChange" {
            let params   = payload["params"] as? [String: Any]
            let changes  = params?["contentChanges"] as? [[String: Any]]
            let range    = changes?.first?["range"] as? [String: Any]
            // Post back on main actor since the harness is @MainActor
            let captured = harness
            Task { @MainActor in captured?.recordDidChange(range: range) }
        }

        // Respond to all JSON-RPC requests (those with an id)
        guard let id = payload["id"] else { return }

        let result: Any
        if method == "initialize" {
            result = ["capabilities": ["textDocumentSync": 2]] as [String: Any]
        } else {
            result = NSNull()
        }

        guard let responseBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result
        ] as [String: Any]) else { return }

        var framed = Data("Content-Length: \(responseBody.count)\r\n\r\n".utf8)
        framed.append(responseBody)
        standardOutputHandler?(framed)
    }

    func stop() {}
}

