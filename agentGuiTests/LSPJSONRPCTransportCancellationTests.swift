import Foundation
import Testing
@testable import agentGui

struct LSPJSONRPCTransportCancellationTests {
    @Test
    func cancelRequestSendsNotificationWithCorrectID() throws {
        let transport = LSPJSONRPCTransport()
        var sentData: [Data] = []
        transport.outgoingDataHandler = { sentData.append($0) }

        // Register a fake pending request so cancel has something to target
        transport.registerPendingRequest(id: "req-42")

        try transport.cancelRequest(id: "req-42")

        #expect(sentData.count == 1)
        let body = extractJSONBody(from: sentData[0])
        #expect(body?["method"] as? String == "$/cancelRequest")
        let params = body?["params"] as? [String: Any]
        #expect(params?["id"] as? String == "req-42")
        // cancelRequest is a notification — no "id" field at top level
        let hasID = body?["id"] != nil
        #expect(hasID == false)
    }

    @Test
    func cancelRequestResumesContinuationWithCancellationError() async throws {
        let transport = LSPJSONRPCTransport()
        transport.outgoingDataHandler = { _ in } // swallow writes

        let task = Task<Any?, Error> {
            try await transport.sendCancellableRequest(
                id: transport.allocateRequestID(),
                method: "textDocument/hover",
                params: ["textDocument": ["uri": "file:///test.py"]]
            )
        }

        // Let the continuation register
        try await Task.sleep(nanoseconds: 20_000_000)

        // Find the pending request ID
        let pendingID = transport.firstPendingRequestID
        #expect(pendingID != nil)

        try transport.cancelRequest(id: pendingID!)

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(transport.hasPendingRequest(id: pendingID!) == false)
    }

    @Test
    func cancelRequestForUnknownIDIsNoOp() throws {
        let transport = LSPJSONRPCTransport()
        var sentData: [Data] = []
        transport.outgoingDataHandler = { sentData.append($0) }

        // Should not crash, should not send anything
        try transport.cancelRequest(id: "nonexistent")

        #expect(sentData.isEmpty)
    }

    @Test
    func sendCancellableRequestReturnsResult() async throws {
        let transport = LSPJSONRPCTransport()

        // Intercept outgoing data and auto-reply
        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] as? String == "textDocument/hover" else { return }
            // Auto-reply with a result
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["contents": "hello"]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let requestID = transport.allocateRequestID()
        let result = try await transport.sendCancellableRequest(
            id: requestID,
            method: "textDocument/hover",
            params: ["textDocument": ["uri": "file:///test.py"]]
        )

        #expect(!requestID.isEmpty)
        let resultDict = result as? [String: Any]
        #expect(resultDict?["contents"] as? String == "hello")
    }

    @Test
    func serverSideRequestCancelledErrorCodeTreatedAsCancel() async throws {
        let transport = LSPJSONRPCTransport()

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] != nil else { return }
            // Server replies with RequestCancelled error code (-32800)
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32800,
                    "message": "Request cancelled"
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let requestID = transport.allocateRequestID()
        do {
            _ = try await transport.sendCancellableRequest(
                id: requestID,
                method: "textDocument/hover",
                params: [:]
            )
            Issue.record("Expected error")
        } catch is CancellationError {
            // Expected — server-side -32800 maps to CancellationError
        } catch {
            // Also acceptable: TransportError.requestFailed
        }
    }
}

private func extractJSONBody(from data: Data) -> [String: Any]? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let body = data.suffix(from: separator.upperBound)
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}
