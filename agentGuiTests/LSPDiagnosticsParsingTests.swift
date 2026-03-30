import Foundation
import Testing
@testable import agentGui

struct LSPDiagnosticsParsingTests {
    @MainActor
    @Test
    func publishDiagnosticsParsesExplicitEndRangeFromNotification() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: DiagnosticsParsingAdapter()
        )
        client.configureNotificationHandling(workspaceRoot: "/tmp")

        let payload = try transport.makeOutgoingData(jsonObject: [
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": "file:///tmp/Sample.swift",
                "version": 7,
                "diagnostics": [
                    [
                        "message": "problem",
                        "severity": 2,
                        "source": "swift",
                        "range": [
                            "start": ["line": 1, "character": 3],
                            "end": ["line": 1, "character": 8]
                        ]
                    ]
                ]
            ]
        ])

        _ = try transport.receive(payload)
        await Task.yield()
        try await Task.sleep(nanoseconds: 10_000_000)

        let snapshot = try #require(client.diagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.swift"
        ))
        let diagnostic = try #require(snapshot.diagnostics.first)

        #expect(snapshot.documentVersion == 7)
        #expect(diagnostic.line == 1)
        #expect(diagnostic.character == 3)
        #expect(diagnostic.endLine == 1)
        #expect(diagnostic.endCharacter == 8)
    }

    @MainActor
    @Test
    func publishDiagnosticsLeavesEndRangeNilWhenProtocolOmitsIt() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: DiagnosticsParsingAdapter()
        )
        client.configureNotificationHandling(workspaceRoot: "/tmp")

        let payload = try transport.makeOutgoingData(jsonObject: [
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": "file:///tmp/Sample.swift",
                "diagnostics": [
                    [
                        "message": "problem",
                        "severity": 1,
                        "range": [
                            "start": ["line": 0, "character": 2]
                        ]
                    ]
                ]
            ]
        ])

        _ = try transport.receive(payload)
        await Task.yield()
        try await Task.sleep(nanoseconds: 10_000_000)

        let snapshot = try #require(client.diagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.swift"
        ))
        let diagnostic = try #require(snapshot.diagnostics.first)

        #expect(diagnostic.line == 0)
        #expect(diagnostic.character == 2)
        #expect(diagnostic.endLine == nil)
        #expect(diagnostic.endCharacter == nil)
    }
}

private struct DiagnosticsParsingAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}