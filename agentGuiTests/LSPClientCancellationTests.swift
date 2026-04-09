import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPClientCancellationTests {
    @Test
    func cancellableHoverReturnsHandleWithRequestID() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        // Auto-reply hover
        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] as? String == "textDocument/hover" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["contents": ["kind": "markdown", "value": "test hover"]]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableHover(uri: "file:///test.py", line: 0, character: 0)
        let text = try await handle.result()
        #expect(!handle.requestID.isEmpty)
        #expect(text == "test hover")
    }

    @Test
    func cancellingHoverHandleThrowsCancellationError() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )
        transport.outgoingDataHandler = { _ in } // Don't reply

        let handle = client.cancellableHover(uri: "file:///test.py", line: 0, character: 0)

        // Let continuation register
        try await Task.sleep(nanoseconds: 20_000_000)

        handle.cancel()

        do {
            _ = try await handle.result()
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // OK
        }
    }

    @Test
    func cancellableDefinitionReturnsLocation() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] as? String == "textDocument/definition" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "uri": "file:///test.py",
                    "range": [
                        "start": ["line": 5, "character": 2],
                        "end":   ["line": 5, "character": 10]
                    ]
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableDefinition(uri: "file:///test.py", line: 1, character: 3)
        let location = try await handle.result()
        #expect(location?.line == 5)
        #expect(location?.character == 2)
    }

    @Test
    func cancellableReferencesReturnsList() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] as? String == "textDocument/references" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    [
                        "uri": "file:///test.py",
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end":   ["line": 0, "character": 4]
                        ]
                    ]
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableReferences(uri: "file:///test.py", line: 0, character: 0)
        let locations = try await handle.result()
        #expect(locations.count == 1)
    }
}

private struct StubLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private func extractJSONBody(from data: Data) -> [String: Any]? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let body = data.suffix(from: separator.upperBound)
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}
