import Foundation
import Testing
@testable import agentGui

@MainActor
struct FeishuClientLiveTests {
    @Test func startAndSendEmitDebugLogs() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_sent_1"}}
                """
            )
        ])
        var logs: [String] = []
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: RecordingFeishuInboundEventSource(),
            uuidProvider: { "uuid-fixed" },
            nowProvider: { Date(timeIntervalSince1970: 100) },
            debugLogger: { logs.append($0) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        _ = try await client.sendText(chatID: "oc_chat_1", text: "你好", replyToMessageID: nil)

        #expect(logs.contains(where: { $0.contains("start app_id=cli_test") }))
        #expect(logs.contains(where: { $0.contains("fetch tenant_access_token") }))
        #expect(logs.contains(where: { $0.contains("send message chat_id=oc_chat_1") }))
        #expect(logs.contains(where: { $0.contains("send message succeeded message_id=om_sent_1") }))
    }

    @Test func sendTextFetchesTenantTokenThenCreatesChatMessage() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_sent_1"}}
                """
            )
        ])
        let eventSource = RecordingFeishuInboundEventSource()
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: eventSource,
            uuidProvider: { "uuid-fixed" },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        let messageID = try await client.sendText(chatID: "oc_chat_1", text: "你好", replyToMessageID: nil)

        #expect(messageID == "om_sent_1")
        #expect(transport.requests.count == 2)

        let tokenRequest = try #require(transport.requests.first)
        #expect(tokenRequest.url?.path == "/open-apis/auth/v3/tenant_access_token/internal")
        #expect(tokenRequest.httpMethod == "POST")
        #expect(String(data: try #require(tokenRequest.httpBody), encoding: .utf8)?.contains("cli_test") == true)

        let sendRequest = try #require(transport.requests.last)
        #expect(sendRequest.url?.path == "/open-apis/im/v1/messages")
        #expect(sendRequest.url?.query == "receive_id_type=chat_id")
        #expect(sendRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tenant-token-1")
        let sendBody = String(data: try #require(sendRequest.httpBody), encoding: .utf8) ?? ""
        #expect(sendBody.contains("oc_chat_1"))
        #expect(sendBody.contains("\\\"text\\\":\\\"你好\\\""))
        #expect(sendBody.contains("uuid-fixed"))
    }

    @Test func sendTextUsesReplyEndpointWhenReplyMessageIDProvided() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages/om_source/reply")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_reply_1"}}
                """
            )
        ])
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: RecordingFeishuInboundEventSource(),
            uuidProvider: { "uuid-fixed" },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        let messageID = try await client.sendText(chatID: "oc_chat_1", text: "回复内容", replyToMessageID: "om_source")

        #expect(messageID == "om_reply_1")
        let replyRequest = try #require(transport.requests.last)
        #expect(replyRequest.url?.path == "/open-apis/im/v1/messages/om_source/reply")
        let replyBody = String(data: try #require(replyRequest.httpBody), encoding: .utf8) ?? ""
        #expect(replyBody.contains("回复内容"))
        #expect(replyBody.contains("uuid-fixed"))
    }

    @Test func sendMessageCreatesPostPayload() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_post_1"}}
                """
            )
        ])
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: RecordingFeishuInboundEventSource(),
            uuidProvider: { "uuid-fixed" },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        let messageID = try await client.sendMessage(
            chatID: "oc_chat_1",
            payload: FeishuRenderedMessagePayload(
                msgType: "post",
                content: #"{"zh_cn":{"title":"","content":[[{"tag":"text","text":"你好"}]]}}"#
            ),
            replyToMessageID: nil
        )

        #expect(messageID == "om_post_1")
        let sendRequest = try #require(transport.requests.last)
        let sendBody = String(data: try #require(sendRequest.httpBody), encoding: .utf8) ?? ""
        #expect(sendBody.contains("\"msg_type\":\"post\""))
        #expect(sendBody.contains("\\\"zh_cn\\\""))
    }

    @Test func sendMessageUsesInteractiveReplyPayload() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages/om_source/reply")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_card_1"}}
                """
            )
        ])
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: RecordingFeishuInboundEventSource(),
            uuidProvider: { "uuid-fixed" },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        let messageID = try await client.sendMessage(
            chatID: "oc_chat_1",
            payload: FeishuRenderedMessagePayload(
                msgType: "interactive",
                content: #"{"header":{"title":{"tag":"plain_text","content":"Agent Reply"}},"elements":[{"tag":"div","text":{"tag":"lark_md","content":"卡片内容"}}]}"#
            ),
            replyToMessageID: "om_source"
        )

        #expect(messageID == "om_card_1")
        let replyRequest = try #require(transport.requests.last)
        let replyBody = String(data: try #require(replyRequest.httpBody), encoding: .utf8) ?? ""
        #expect(replyBody.contains("\"msg_type\":\"interactive\""))
        #expect(replyBody.contains("卡片内容"))
        #expect(replyBody.contains("uuid-fixed"))
    }

    @Test func sendTextReusesCachedTenantTokenBeforeExpiry() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_sent_1"}}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id")!,
                body: """
                {"code":0,"msg":"success","data":{"message_id":"om_sent_2"}}
                """
            )
        ])
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: RecordingFeishuInboundEventSource(),
            uuidProvider: { UUID().uuidString },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }
        _ = try await client.sendText(chatID: "oc_chat_1", text: "first", replyToMessageID: nil)
        _ = try await client.sendText(chatID: "oc_chat_1", text: "second", replyToMessageID: nil)

        let tokenRequests = transport.requests.filter { $0.url?.path == "/open-apis/auth/v3/tenant_access_token/internal" }
        #expect(tokenRequests.count == 1)
    }

    @Test func startBootstrapsInboundEventSourceWithTokenProvider() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!,
                body: """
                {"code":0,"msg":"ok","tenant_access_token":"tenant-token-1","expire":7200}
                """
            )
        ])
        let eventSource = RecordingFeishuInboundEventSource()
        let client = LiveFeishuClient(
            transport: transport,
            eventSource: eventSource,
            uuidProvider: { UUID().uuidString },
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        try await client.start(credentials: .init(appID: "cli_test", appSecret: "secret_test")) { _ in }

        #expect(eventSource.startCallCount == 1)
        let resolvedToken = try await eventSource.resolveToken()
        #expect(resolvedToken == "tenant-token-1")
    }
}

private final class RecordingFeishuTransport: FeishuTransport {
    struct Response {
        let expectedURL: URL
        let data: Data
        let response: URLResponse

        static func json(url: URL, statusCode: Int = 200, body: String) -> Response {
            Response(
                expectedURL: url,
                data: Data(body.utf8),
                response: HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json; charset=utf-8"])!
            )
        }
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let next = responses.removeFirst()
        #expect(request.url == next.expectedURL)
        return (next.data, next.response)
    }
}

@MainActor
private final class RecordingFeishuInboundEventSource: FeishuInboundEventSource {
    private var tokenProvider: (@Sendable () async throws -> String)?
    private(set) var startCallCount = 0

    func start(
        credentials: FeishuCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws {
        _ = credentials
        _ = onEvent
        _ = onCallback
        self.tokenProvider = tokenProvider
        startCallCount += 1
    }

    func stop() async {}

    func resolveToken() async throws -> String {
        try await tokenProvider?() ?? ""
    }
}