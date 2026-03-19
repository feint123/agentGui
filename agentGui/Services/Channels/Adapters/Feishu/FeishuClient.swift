import Foundation

struct FeishuCallbackEnvelope: Equatable, Sendable {
    let messageType: String
    let payload: Data
    let headers: [String: String]
}

@MainActor
protocol FeishuClient {
    func start(
        credentials: FeishuCredentials,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void
    ) async throws

    func stop() async

    func sendMessage(
        chatID: String,
        payload: FeishuRenderedMessagePayload,
        replyToMessageID: String?
    ) async throws -> String

    func updateMessage(
        messageID: String,
        payload: FeishuRenderedMessagePayload
    ) async throws

    func patchMessage(
        messageID: String,
        payload: FeishuRenderedMessagePayload
    ) async throws

    func sendText(
        chatID: String,
        text: String,
        replyToMessageID: String?
    ) async throws -> String
}

protocol FeishuTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

@MainActor
protocol FeishuInboundEventSource: AnyObject {
    func start(
        credentials: FeishuCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws

    func stop() async
}

extension FeishuInboundEventSource {
    func start(
        credentials: FeishuCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void
    ) async throws {
        try await start(
            credentials: credentials,
            tokenProvider: tokenProvider,
            onEvent: onEvent,
            onCallback: { _ in nil }
        )
    }
}

struct URLSessionFeishuTransport: FeishuTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

@MainActor
final class NoopFeishuInboundEventSource: FeishuInboundEventSource {
    func start(
        credentials: FeishuCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws {
        _ = credentials
        _ = tokenProvider
        _ = onEvent
        _ = onCallback
    }

    func stop() async {}
}

@MainActor
final class LiveFeishuClient: FeishuClient {
    enum ClientError: LocalizedError {
        case missingCredentials
        case invalidResponse
        case apiError(code: Int, message: String)
        case httpError(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Feishu 凭证未初始化"
            case .invalidResponse:
                return "Feishu 返回了无法解析的响应"
            case .apiError(let code, let message):
                return "Feishu API 错误 (\(code)): \(message)"
            case .httpError(let statusCode, let message):
                return "Feishu HTTP 错误 (\(statusCode)): \(message)"
            }
        }
    }

    private struct CachedTenantAccessToken {
        let value: String
        let expiresAt: Date

        func isValid(at now: Date) -> Bool {
            now.addingTimeInterval(300) < expiresAt
        }
    }

    private struct TenantAccessTokenRequest: Encodable {
        let appID: String
        let appSecret: String

        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case appSecret = "app_secret"
        }
    }

    private struct TenantAccessTokenResponse: Decodable {
        let code: Int
        let msg: String
        let tenantAccessToken: String?
        let expire: Int?

        enum CodingKeys: String, CodingKey {
            case code
            case msg
            case tenantAccessToken = "tenant_access_token"
            case expire
        }
    }

    private struct SendMessageRequest: Encodable {
        let receiveID: String
        let msgType: String
        let content: String
        let uuid: String

        enum CodingKeys: String, CodingKey {
            case receiveID = "receive_id"
            case msgType = "msg_type"
            case content
            case uuid
        }
    }

    private struct ReplyMessageRequest: Encodable {
        let msgType: String
        let content: String
        let uuid: String
        let replyInThread: Bool

        enum CodingKeys: String, CodingKey {
            case msgType = "msg_type"
            case content
            case uuid
            case replyInThread = "reply_in_thread"
        }
    }

    private struct MessageCreateResponse: Decodable {
        let code: Int
        let msg: String
        let data: MessageData?

        struct MessageData: Decodable {
            let messageID: String?

            enum CodingKeys: String, CodingKey {
                case messageID = "message_id"
            }
        }
    }

    private struct MessageMutationRequest: Encodable {
        let msgType: String
        let content: String

        enum CodingKeys: String, CodingKey {
            case msgType = "msg_type"
            case content
        }
    }

    private struct MessageMutationResponse: Decodable {
        let code: Int
        let msg: String
    }

    private struct TextContent: Encodable {
        let text: String
    }

    private let transport: any FeishuTransport
    private let eventSource: any FeishuInboundEventSource
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let renderer: FeishuOutboundMessageRenderer
    private let uuidProvider: () -> String
    private let nowProvider: () -> Date
    private let debugLogger: @Sendable (String) -> Void
    private var credentials: FeishuCredentials?
    private var cachedToken: CachedTenantAccessToken?

    init(
        transport: (any FeishuTransport)? = nil,
        eventSource: (any FeishuInboundEventSource)? = nil,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        renderer: FeishuOutboundMessageRenderer? = nil,
        uuidProvider: @escaping () -> String = { UUID().uuidString },
        nowProvider: @escaping () -> Date = Date.init,
        debugLogger: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        let resolvedTransport = transport ?? URLSessionFeishuTransport()
        self.transport = resolvedTransport
        self.eventSource = eventSource ?? FeishuLongConnectionEventSource(transport: resolvedTransport)
        self.decoder = decoder
        self.encoder = encoder
        self.renderer = renderer ?? FeishuOutboundMessageRenderer(encoder: encoder)
        self.uuidProvider = uuidProvider
        self.nowProvider = nowProvider
        self.debugLogger = debugLogger
    }

    func start(
        credentials: FeishuCredentials,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void
    ) async throws {
        debugLog("start app_id=\(credentials.appID)")
        self.credentials = credentials
        try await eventSource.start(
            credentials: credentials,
            tokenProvider: { [weak self] in
                guard let self else { throw ClientError.missingCredentials }
                return try await self.validTenantAccessToken()
            },
            onEvent: onEvent,
            onCallback: { _ in nil }
        )
    }

    func stop() async {
        debugLog("stop")
        cachedToken = nil
        credentials = nil
        await eventSource.stop()
    }

    func sendText(
        chatID: String,
        text: String,
        replyToMessageID: String?
    ) async throws -> String {
        let payload = try renderer.render(text: text, format: .text, title: nil)
        return try await sendMessage(chatID: chatID, payload: payload, replyToMessageID: replyToMessageID)
    }

    func sendMessage(
        chatID: String,
        payload: FeishuRenderedMessagePayload,
        replyToMessageID: String?
    ) async throws -> String {
        let token = try await validTenantAccessToken()

        let uuid = String(uuidProvider().prefix(50))

        let url: URL
        let bodyData: Data
        if let replyToMessageID {
            url = URL(string: "https://open.feishu.cn/open-apis/im/v1/messages/\(replyToMessageID)/reply")!
            bodyData = try encoder.encode(
                ReplyMessageRequest(
                    msgType: payload.msgType,
                    content: payload.content,
                    uuid: uuid,
                    replyInThread: false
                )
            )
        } else {
            var components = URLComponents(string: "https://open.feishu.cn/open-apis/im/v1/messages")!
            components.queryItems = [URLQueryItem(name: "receive_id_type", value: "chat_id")]
            guard let resolved = components.url else { throw ClientError.invalidResponse }
            url = resolved
            bodyData = try encoder.encode(
                SendMessageRequest(
                    receiveID: chatID,
                    msgType: payload.msgType,
                    content: payload.content,
                    uuid: uuid
                )
            )
        }

        debugLog("send message chat_id=\(chatID) reply_to=\(replyToMessageID ?? "nil") url=\(url.absoluteString) msg_type=\(payload.msgType) content_length=\(payload.content.count)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await transport.data(for: request)
        try validateHTTPResponse(response, data: data)
        if let httpResponse = response as? HTTPURLResponse {
            debugLog("send message response status=\(httpResponse.statusCode) bytes=\(data.count)")
        }
        let payload = try decoder.decode(MessageCreateResponse.self, from: data)
        guard payload.code == 0 else {
            throw ClientError.apiError(code: payload.code, message: payload.msg)
        }
        guard let messageID = payload.data?.messageID, !messageID.isEmpty else {
            throw ClientError.invalidResponse
        }
        debugLog("send message succeeded message_id=\(messageID)")
        return messageID
    }

    func updateMessage(
        messageID: String,
        payload: FeishuRenderedMessagePayload
    ) async throws {
        try await mutateMessage(messageID: messageID, payload: payload, httpMethod: "PUT")
    }

    func patchMessage(
        messageID: String,
        payload: FeishuRenderedMessagePayload
    ) async throws {
        try await mutateMessage(messageID: messageID, payload: payload, httpMethod: "PATCH")
    }

    private func validTenantAccessToken() async throws -> String {
        if let cachedToken, cachedToken.isValid(at: nowProvider()) {
            debugLog("reuse cached tenant_access_token expires_at=\(cachedToken.expiresAt.timeIntervalSince1970)")
            return cachedToken.value
        }
        let credentials = try requireCredentials()
        let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            TenantAccessTokenRequest(appID: credentials.appID, appSecret: credentials.appSecret)
        )

        debugLog("fetch tenant_access_token url=\(url.absoluteString) app_id=\(credentials.appID)")

        let (data, response) = try await transport.data(for: request)
        try validateHTTPResponse(response, data: data)
        if let httpResponse = response as? HTTPURLResponse {
            debugLog("tenant_access_token response status=\(httpResponse.statusCode) bytes=\(data.count)")
        }
        let payload = try decoder.decode(TenantAccessTokenResponse.self, from: data)
        guard payload.code == 0 else {
            throw ClientError.apiError(code: payload.code, message: payload.msg)
        }
        guard let token = payload.tenantAccessToken,
              let expire = payload.expire else {
            throw ClientError.invalidResponse
        }
        cachedToken = CachedTenantAccessToken(
            value: token,
            expiresAt: nowProvider().addingTimeInterval(TimeInterval(expire))
        )
        debugLog("tenant_access_token cached expire_seconds=\(expire)")
        return token
    }

    private func requireCredentials() throws -> FeishuCredentials {
        guard let credentials else {
            throw ClientError.missingCredentials
        }
        return credentials
    }

    private func mutateMessage(
        messageID: String,
        payload: FeishuRenderedMessagePayload,
        httpMethod: String
    ) async throws {
        let token = try await validTenantAccessToken()
        let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/messages/\(messageID)")!
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            MessageMutationRequest(
                msgType: payload.msgType,
                content: payload.content
            )
        )

        debugLog("\(httpMethod.lowercased()) message message_id=\(messageID) msg_type=\(payload.msgType) content_length=\(payload.content.count)")

        let (data, response) = try await transport.data(for: request)
        try validateHTTPResponse(response, data: data)
        let mutationResponse = try decoder.decode(MessageMutationResponse.self, from: data)
        guard mutationResponse.code == 0 else {
            throw ClientError.apiError(code: mutationResponse.code, message: mutationResponse.msg)
        }
        debugLog("\(httpMethod.lowercased()) message succeeded message_id=\(messageID)")
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            debugLog("http error status=\(httpResponse.statusCode) body_prefix=\(message.prefix(300))")
            throw ClientError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func debugLog(_ message: String) {
        debugLogger("[feishu-client] \(message)")
    }
}