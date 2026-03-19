import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPClientHandlerTests {

    @Test func permissionRequestRouteDecodesTypedRequestAndEncodesTypedResponse() async throws {
        let handler = MockACPClientHandler()
        let router = ACPMessageRouter.clientRouter(handler: handler)
        let request = ACPRequestPermissionRequest(
            meta: nil,
            options: [
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow once", optionID: "allow-once")
            ],
            sessionID: "session-10",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: nil,
                kind: "execute",
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                status: "pending",
                title: "Run command",
                toolCallID: "tool-1"
            )
        )

        let params = try ACPJSONValue.fromEncodable(request)
        let result = try await router.handle(
            method: ACPMethodCatalog.Client.sessionRequestPermission,
            params: params,
            isNotification: false
        )

        let responsePayload = try #require(result)
        let response = try responsePayload.decode(ACPRequestPermissionResponse.self)

        #expect(handler.permissionRequest?.sessionID == "session-10")
        #expect(handler.permissionRequest?.toolCall.toolCallID == "tool-1")
        switch response.outcome {
        case .selected(let outcome):
            #expect(outcome.optionID == "allow-once")
        default:
            Issue.record("Expected selected permission outcome")
        }
    }

    @Test func terminalCreateRouteDecodesTypedRequestAndEncodesTypedResponse() async throws {
        let handler = MockACPClientHandler()
        let router = ACPMessageRouter.clientRouter(handler: handler)
        let request = ACPCreateTerminalRequest(
            meta: nil,
            args: ["-lc", "pwd"],
            command: "/bin/zsh",
            cwd: "/tmp/project",
            env: [ACPEnvVariable(meta: nil, name: "TERM", value: "xterm-256color")],
            outputByteLimit: 2048,
            sessionID: "session-11"
        )

        let params = try ACPJSONValue.fromEncodable(request)
        let result = try await router.handle(
            method: ACPMethodCatalog.Client.terminalCreate,
            params: params,
            isNotification: false
        )

        let responsePayload = try #require(result)
        let response = try responsePayload.decode(ACPCreateTerminalResponse.self)

        #expect(handler.createTerminalRequest?.command == "/bin/zsh")
        #expect(handler.createTerminalRequest?.outputByteLimit == 2048)
        #expect(response.terminalID == "terminal-1")
    }

    @Test func sessionUpdateNotificationDecodesTypedNotification() async throws {
        let handler = MockACPClientHandler()
        let router = ACPMessageRouter.clientRouter(handler: handler)
        let notification = ACPSessionNotification(
            meta: nil,
            sessionID: "session-12",
            update: .agentThoughtChunk(
                ACPContentChunk(
                    meta: nil,
                    content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "thinking"))
                )
            )
        )

        let params = try ACPJSONValue.fromEncodable(notification)
        let result = try await router.handle(
            method: ACPMethodCatalog.Client.sessionUpdate,
            params: params,
            isNotification: true
        )

        #expect(result == nil)
        #expect(handler.sessionUpdate?.sessionID == "session-12")
        switch handler.sessionUpdate?.update {
        case .agentThoughtChunk(let chunk):
            switch chunk.content {
            case .text(let block):
                #expect(block.text == "thinking")
            default:
                Issue.record("Expected text content in thought chunk")
            }
        default:
            Issue.record("Expected agent thought chunk update")
        }
    }
}

@MainActor
private final class MockACPClientHandler: ACPClientHandler {
    var sessionUpdate: ACPSessionNotification?
    var permissionRequest: ACPRequestPermissionRequest?
    var createTerminalRequest: ACPCreateTerminalRequest?

    func handleSessionUpdate(_ notification: ACPSessionNotification) async {
        sessionUpdate = notification
    }

    func handleRequestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse? {
        permissionRequest = request
        return ACPRequestPermissionResponse(
            meta: nil,
            outcome: .selected(ACPSelectedPermissionOutcome(meta: nil, optionID: "allow-once"))
        )
    }

    func handleCreateTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse? {
        createTerminalRequest = request
        return ACPCreateTerminalResponse(meta: nil, terminalID: "terminal-1")
    }
}