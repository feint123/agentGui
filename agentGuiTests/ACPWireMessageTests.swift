import Foundation
import Testing
@testable import agentGui

struct ACPWireMessageTests {

    @Test func providerExtensionRequestUsesUnderscorePrefixedMethod() throws {
        let message = ACPWireMessage.request(
            ACPRequestMessage(
                id: .int(9),
                method: ACPProviderExtensionMethod("_opencode/session/set_model").method,
                params: .object(["sessionId": .string("remote-1")])
            )
        )

        let encoded = try message.encodedLine()
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(text.contains("\"method\":\"_opencode\\/session\\/set_model\""))
    }

    @Test func requestMessageEncodesAsNewlineDelimitedJSON() throws {
        let message = ACPWireMessage.request(
            ACPRequestMessage(
                id: .int(7),
                method: ACPMethodCatalog.Agent.initialize,
                params: .object(["protocolVersion": .number(1)])
            )
        )

        let encoded = try message.encodedLine()
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(text.hasSuffix("\n"))
        #expect(text.contains("\"method\":\"initialize\""))
        #expect(text.contains("\"id\":7"))
    }

    @Test func decodeParsesRequestNotificationAndResponseShapes() throws {
        let request = try ACPWireMessage.decode(lineData: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n".utf8))
        let notification = try ACPWireMessage.decode(lineData: Data("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}\n".utf8))
        let response = try ACPWireMessage.decode(lineData: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n".utf8))

        #expect(request == .request(ACPRequestMessage(id: .int(1), method: "initialize", params: .object([:] ))))
        #expect(notification == .notification(ACPNotificationMessage(method: "session/update", params: .object([:] ))))
        #expect(response == .response(ACPResponseMessage(id: .int(1), result: .object([:]), error: nil)))
    }

    @Test func requestErrorPreservesStandardJSONRPCCodes() {
        let error = ACPRequestError.methodNotFound("session/resume")

        #expect(error.code == -32601)
        #expect(error.message == "Method not found")
        #expect(error.data == .object(["method": .string("session/resume")]))
    }

    @Test func decodeRejectsNonJSONRPC2Envelope() {
        #expect(throws: ACPTransportError.invalidMessageShape) {
            _ = try ACPWireMessage.decode(lineData: Data("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}\n".utf8))
        }
    }

    @Test func decodeRejectsResponseContainingResultAndError() {
        #expect(throws: ACPTransportError.invalidMessageShape) {
            _ = try ACPWireMessage.decode(
                lineData: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":-32603,\"message\":\"boom\"}}\n".utf8)
            )
        }
    }
}