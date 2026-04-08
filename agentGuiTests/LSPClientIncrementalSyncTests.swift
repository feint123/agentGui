import Testing
import Foundation
@testable import agentGui

@MainActor
struct LSPClientIncrementalSyncTests {

    // MARK: - Helpers

    /// Parses an LSP-framed message (Content-Length header + JSON body) into a dictionary.
    private func parseMessage(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let bodyData = data[headerEnd.upperBound...]
        return try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    }

    private func makeCapturingClient(syncKind: TextDocumentSyncKind) -> (LSPClient, captured: CapturedMessages) {
        let transport = LSPJSONRPCTransport()
        let captured = CapturedMessages()
        transport.outgoingDataHandler = { [weak captured] data in
            captured?.messages.append(data)
        }
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        var caps = LSPServerCapabilityHints.allDisabled
        caps.syncKind = syncKind
        client.setCapabilitiesForTesting(caps)
        return (client, captured)
    }

    // MARK: - Tests

    @Test func incrementalServerReceivesRangedContentChange() throws {
        let (client, captured) = makeCapturingClient(syncKind: .incremental)
        client.openDocument(uri: "file:///test.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///test.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        let first   = try #require(changes?.first)

        #expect(first["range"] != nil, "incremental change must include range")
        #expect(first["text"] as? String == "Swift")

        let range = first["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"]      as? Int == 0)
        #expect(start?["character"] as? Int == 6)
        #expect(end?["line"]        as? Int == 0)
        #expect(end?["character"]   as? Int == 11)
    }

    @Test func fullSyncServerReceivesTextOnlyContentChange() throws {
        let (client, captured) = makeCapturingClient(syncKind: .full)
        client.openDocument(uri: "file:///test.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///test.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        let first   = try #require(changes?.first)

        #expect(first["range"] == nil, "full sync must NOT include range")
        #expect(first["text"] as? String == "hello Swift")
    }

    @Test func incrementalUpdateIncreasesDocumentVersion() {
        let (client, _) = makeCapturingClient(syncKind: .incremental)
        client.openDocument(uri: "file:///v.py", languageID: "python", text: "initial")

        let snapshot = client.updateDocument(
            uri: "file:///v.py",
            replacing: NSRange(location: 0, length: 7),
            insertedText: "updated",
            newText: "updated"
        )
        #expect(snapshot?.version == 2)
    }

    @Test func nilCapabilitiesFallBackToFullSync() throws {
        let transport = LSPJSONRPCTransport()
        let captured = CapturedMessages()
        transport.outgoingDataHandler = { data in captured.messages.append(data) }
        // Do NOT set capabilities
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        client.openDocument(uri: "file:///nil.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///nil.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        #expect(changes?.first?["range"] == nil, "nil capabilities must use full sync")
    }
}

/// Helper to accumulate captured outgoing messages across async boundaries.
@MainActor
private final class CapturedMessages {
    var messages: [Data] = []
}
