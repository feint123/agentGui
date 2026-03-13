import Foundation
import Testing
@testable import agentGui

struct LSPClientTests {

    @Test func initializeSessionSendsInitializeRequestThenInitializedNotification() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: GenericLSPServerAdapter()
        )
        let harness = LSPTransportHarness(transport: transport)
        let server = LSPServerDefinition(
            id: "typescript-language-server",
            displayName: "TypeScript Language Server",
            launchCommand: "typescript-language-server",
            launchArguments: ["--stdio"],
            supportedLanguageIDs: ["typescript"],
            defaultFileGlobs: ["**/*.ts"],
            rootMarkers: ["package.json"],
            adapterKind: .generic
        )

        harness.onRequest(method: "initialize") { request in
            #expect(request.params?["rootUri"]?.stringValue == "file:///repo")
            #expect(request.params?["capabilities"] != nil)

            return [
                "capabilities": [
                    "definitionProvider": true,
                    "referencesProvider": true,
                    "hoverProvider": true,
                    "documentSymbolProvider": true,
                    "workspaceSymbolProvider": true
                ]
            ]
        }

        let capabilities = try await client.initializeSession(server: server, workspaceRoot: "/repo")

        #expect(capabilities.supportsDefinition == true)
        #expect(harness.notifications == ["initialized"])
    }

    @Test func definitionSendsJSONRPCRequestAndReturnsFirstLocationURI() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: GenericLSPServerAdapter()
        )
        let harness = LSPTransportHarness(transport: transport)

        harness.onRequest(method: "textDocument/definition") { request in
            #expect(request.params?["textDocument"]?["uri"]?.stringValue == "file:///repo/src/app.ts")
            #expect(request.params?["position"]?["line"]?.intValue == 3)
            #expect(request.params?["position"]?["character"]?.intValue == 7)

            return [
                [
                    "uri": "file:///repo/src/definition.ts",
                    "range": [
                        "start": ["line": 10, "character": 2],
                        "end": ["line": 10, "character": 8]
                    ]
                ]
            ]
        }

        let result = try await client.definition(uri: "file:///repo/src/app.ts", line: 3, character: 7)

        #expect(result?.uri == "file:///repo/src/definition.ts")
        #expect(result?.line == 10)
        #expect(result?.character == 2)
    }

    @Test func referencesReturnsAllResolvedLocations() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: GenericLSPServerAdapter()
        )
        let harness = LSPTransportHarness(transport: transport)

        harness.onRequest(method: "textDocument/references") { _ in
            [
                [
                    "uri": "file:///repo/src/a.ts",
                    "range": [
                        "start": ["line": 1, "character": 0],
                        "end": ["line": 1, "character": 4]
                    ]
                ],
                [
                    "uri": "file:///repo/src/b.ts",
                    "range": [
                        "start": ["line": 9, "character": 3],
                        "end": ["line": 9, "character": 7]
                    ]
                ]
            ]
        }

        let result = try await client.references(uri: "file:///repo/src/app.ts", line: 1, character: 2)

        #expect(result.count == 2)
        #expect(result.map(\.uri) == ["file:///repo/src/a.ts", "file:///repo/src/b.ts"])
    }

    @Test func hoverReturnsPlainTextFromMarkupContent() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: GenericLSPServerAdapter()
        )
        let harness = LSPTransportHarness(transport: transport)

        harness.onRequest(method: "textDocument/hover") { _ in
            [
                "contents": [
                    "kind": "markdown",
                    "value": "```ts\nconst answer: number\n```"
                ]
            ]
        }

        let result = try await client.hover(uri: "file:///repo/src/app.ts", line: 0, character: 5)

        #expect(result == "```ts\nconst answer: number\n```")
    }
}

private final class LSPTransportHarness {
    struct Request {
        let id: String
        let method: String
        let params: [String: JSONTestValue]?
    }

    private let transport: LSPJSONRPCTransport
    private var responders: [String: (Request) -> Any] = [:]
    private(set) var notifications: [String] = []

    init(transport: LSPJSONRPCTransport) {
        self.transport = transport
        transport.outgoingDataHandler = { [weak self] data in
            self?.handleOutgoing(data: data)
        }
    }

    func onRequest(method: String, responder: @escaping (Request) -> Any) {
        responders[method] = responder
    }

    private func handleOutgoing(data: Data) {
        guard let payload = decodePayload(data: data),
              let method = payload["method"] as? String else {
            Issue.record("Failed to decode outgoing JSON-RPC payload")
            return
        }

        if payload["id"] == nil {
            notifications.append(method)
            return
        }

        guard let id = payload["id"] as? String else {
            Issue.record("Failed to decode outgoing JSON-RPC request id")
            return
        }

        let request = Request(
            id: id,
            method: method,
            params: (payload["params"] as? [String: Any])?.mapValues(JSONTestValue.init)
        )
        guard let responder = responders[method] else {
            Issue.record("No responder registered for \(method)")
            return
        }

        let responseObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": responder(request)
        ]

        do {
            let framed = try transport.makeOutgoingData(jsonObject: responseObject)
            _ = try transport.receive(framed)
        } catch {
            Issue.record("Failed to inject JSON-RPC response: \(error)")
        }
    }

    private func decodePayload(data: Data) -> [String: Any]? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let body = data.suffix(from: separator.upperBound)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private struct JSONTestValue {
    let rawValue: Any

    init(_ rawValue: Any) {
        self.rawValue = rawValue
    }

    var stringValue: String? { rawValue as? String }
    var intValue: Int? { rawValue as? Int }

    subscript(key: String) -> JSONTestValue? {
        guard let dictionary = rawValue as? [String: Any],
              let value = dictionary[key] else {
            return nil
        }
        return JSONTestValue(value)
    }
}