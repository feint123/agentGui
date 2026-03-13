import Foundation
import Testing
@testable import agentGui

struct LSPJSONRPCTransportTests {

    @Test func transportFramesOutgoingMessagesWithContentLengthHeader() throws {
        let transport = LSPJSONRPCTransport()
        let payload = try transport.makeOutgoingData(
            jsonObject: [
                "jsonrpc": "2.0",
                "id": "1",
                "method": "initialize"
            ]
        )
        let text = try #require(String(data: payload, encoding: .utf8))

        #expect(text.contains("Content-Length: "))
        #expect(text.contains("\r\n\r\n"))
        #expect(text.contains("\"method\":\"initialize\""))
    }

    @Test func transportReassemblesFragmentedIncomingMessages() throws {
        let transport = LSPJSONRPCTransport()
        let framed = try transport.makeOutgoingData(
            jsonObject: [
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics"
            ]
        )

        let firstHalf = framed.prefix(framed.count / 2)
        let secondHalf = framed.suffix(framed.count - firstHalf.count)

        let firstMessages = try transport.receive(firstHalf)
        let secondMessages = try transport.receive(secondHalf)

        #expect(firstMessages.isEmpty)
        #expect(secondMessages == [.notification(method: "textDocument/publishDiagnostics")])
    }

    @Test func transportMatchesResponsesToPendingRequestIDs() throws {
        let transport = LSPJSONRPCTransport()
        transport.registerPendingRequest(id: "request-1")

        let framed = try transport.makeOutgoingData(
            jsonObject: [
                "jsonrpc": "2.0",
                "id": "request-1",
                "result": ["capabilities": [:]]
            ]
        )

        let messages = try transport.receive(framed)

        #expect(messages == [.response(id: "request-1")])
        #expect(transport.hasPendingRequest(id: "request-1") == false)
    }

    @Test func transportDispatchesNotificationsToHandler() throws {
        let transport = LSPJSONRPCTransport()
        var receivedMethods: [String] = []
        transport.notificationHandler = { method in
            receivedMethods.append(method)
        }

        let framed = try transport.makeOutgoingData(
            jsonObject: [
                "jsonrpc": "2.0",
                "method": "workspace/didChangeConfiguration"
            ]
        )

        _ = try transport.receive(framed)

        #expect(receivedMethods == ["workspace/didChangeConfiguration"])
    }
}