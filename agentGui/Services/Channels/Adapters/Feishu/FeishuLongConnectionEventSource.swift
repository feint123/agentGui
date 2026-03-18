import Foundation

enum FeishuWebSocketConnectionError: Error, Equatable, Sendable {
    case handshakeFailed(statusCode: Int, message: String?, authErrorCode: Int?)
}

enum FeishuWebSocketLifecycleEvent: Equatable, Sendable {
    case didReceiveHandshakeResponse(httpStatusCode: Int, headers: [String: String])
    case didOpen(negotiatedProtocol: String?)
    case didClose(code: Int, reason: String?)
}

enum FeishuWSFrameMethod: Int32, Equatable, Sendable {
    case control = 0
    case data = 1
}

struct FeishuWSHeader: Equatable, Sendable {
    let key: String
    let value: String
}

struct FeishuWSFrame: Equatable, Sendable {
    let seqID: UInt64
    let logID: UInt64
    let service: Int32
    let method: FeishuWSFrameMethod
    var headers: [FeishuWSHeader]
    let payloadEncoding: String?
    let payloadType: String?
    let payload: Data?
    let logIDNew: String?

    var headerMap: [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.key, $0.value) })
    }
}

struct FeishuWSFrameCodec {
    enum CodecError: Error {
        case invalidField
        case invalidWireType
        case truncatedInput
        case invalidMethod
    }

    func encode(_ frame: FeishuWSFrame) throws -> Data {
        var data = Data()
        encodeVarintField(1, value: frame.seqID, into: &data)
        encodeVarintField(2, value: frame.logID, into: &data)
        encodeVarintField(3, value: UInt64(Int64(frame.service)), into: &data)
        encodeVarintField(4, value: UInt64(frame.method.rawValue), into: &data)
        for header in frame.headers {
            let headerData = try encodeHeader(header)
            encodeLengthDelimitedField(5, value: headerData, into: &data)
        }
        if let payloadEncoding = frame.payloadEncoding {
            encodeLengthDelimitedField(6, value: Data(payloadEncoding.utf8), into: &data)
        }
        if let payloadType = frame.payloadType {
            encodeLengthDelimitedField(7, value: Data(payloadType.utf8), into: &data)
        }
        if let payload = frame.payload {
            encodeLengthDelimitedField(8, value: payload, into: &data)
        }
        if let logIDNew = frame.logIDNew {
            encodeLengthDelimitedField(9, value: Data(logIDNew.utf8), into: &data)
        }
        return data
    }

    func decode(_ data: Data) throws -> FeishuWSFrame {
        var offset = 0
        var seqID: UInt64 = 0
        var logID: UInt64 = 0
        var service: Int32 = 0
        var method: FeishuWSFrameMethod = .control
        var headers: [FeishuWSHeader] = []
        var payloadEncoding: String?
        var payloadType: String?
        var payload: Data?
        var logIDNew: String?

        while offset < data.count {
            let tag = try decodeVarint(from: data, offset: &offset)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch (fieldNumber, wireType) {
            case (1, 0):
                seqID = try decodeVarint(from: data, offset: &offset)
            case (2, 0):
                logID = try decodeVarint(from: data, offset: &offset)
            case (3, 0):
                let value = try decodeVarint(from: data, offset: &offset)
                service = Int32(value)
            case (4, 0):
                let value = try decodeVarint(from: data, offset: &offset)
                guard let resolved = FeishuWSFrameMethod(rawValue: Int32(value)) else {
                    throw CodecError.invalidMethod
                }
                method = resolved
            case (5, 2):
                let nested = try decodeLengthDelimited(from: data, offset: &offset)
                headers.append(try decodeHeader(from: nested))
            case (6, 2):
                payloadEncoding = String(data: try decodeLengthDelimited(from: data, offset: &offset), encoding: .utf8)
            case (7, 2):
                payloadType = String(data: try decodeLengthDelimited(from: data, offset: &offset), encoding: .utf8)
            case (8, 2):
                payload = try decodeLengthDelimited(from: data, offset: &offset)
            case (9, 2):
                logIDNew = String(data: try decodeLengthDelimited(from: data, offset: &offset), encoding: .utf8)
            case (_, 0):
                _ = try decodeVarint(from: data, offset: &offset)
            case (_, 2):
                _ = try decodeLengthDelimited(from: data, offset: &offset)
            default:
                throw CodecError.invalidWireType
            }
        }

        return FeishuWSFrame(
            seqID: seqID,
            logID: logID,
            service: service,
            method: method,
            headers: headers,
            payloadEncoding: payloadEncoding,
            payloadType: payloadType,
            payload: payload,
            logIDNew: logIDNew
        )
    }

    private func encodeHeader(_ header: FeishuWSHeader) throws -> Data {
        var data = Data()
        encodeLengthDelimitedField(1, value: Data(header.key.utf8), into: &data)
        encodeLengthDelimitedField(2, value: Data(header.value.utf8), into: &data)
        return data
    }

    private func decodeHeader(from data: Data) throws -> FeishuWSHeader {
        var offset = 0
        var key = ""
        var value = ""
        while offset < data.count {
            let tag = try decodeVarint(from: data, offset: &offset)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard wireType == 2 else { throw CodecError.invalidWireType }
            let fieldData = try decodeLengthDelimited(from: data, offset: &offset)
            switch fieldNumber {
            case 1:
                key = String(decoding: fieldData, as: UTF8.self)
            case 2:
                value = String(decoding: fieldData, as: UTF8.self)
            default:
                break
            }
        }
        return FeishuWSHeader(key: key, value: value)
    }

    private func encodeVarintField(_ fieldNumber: Int, value: UInt64, into data: inout Data) {
        encodeVarint(UInt64(fieldNumber << 3), into: &data)
        encodeVarint(value, into: &data)
    }

    private func encodeLengthDelimitedField(_ fieldNumber: Int, value: Data, into data: inout Data) {
        encodeVarint(UInt64((fieldNumber << 3) | 2), into: &data)
        encodeVarint(UInt64(value.count), into: &data)
        data.append(value)
    }

    private func encodeVarint(_ value: UInt64, into data: inout Data) {
        var remaining = value
        while true {
            if remaining < 0x80 {
                data.append(UInt8(remaining))
                return
            }
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
    }

    private func decodeVarint(from data: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                throw CodecError.invalidField
            }
        }
        throw CodecError.truncatedInput
    }

    private func decodeLengthDelimited(from data: Data, offset: inout Int) throws -> Data {
        let length = try decodeVarint(from: data, offset: &offset)
        let end = offset + Int(length)
        guard end <= data.count else {
            throw CodecError.truncatedInput
        }
        let slice = data[offset..<end]
        offset = end
        return Data(slice)
    }
}

final class FeishuMultipartAssembler {
    private struct PendingMessage {
        var parts: [Data?]
        let expiresAt: Date
    }

    private var pending: [String: PendingMessage] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func append(frame: FeishuWSFrame, now: Date) -> Data? {
        pending = pending.filter { $0.value.expiresAt > now }
        let headers = frame.headerMap
        guard let payload = frame.payload else { return nil }
        guard let totalString = headers["sum"],
              let total = Int(totalString),
              total > 1,
              let messageID = headers["message_id"],
              let sequenceString = headers["seq"],
              let sequence = Int(sequenceString),
              sequence >= 0,
              sequence < total else {
            return payload
        }

        var buffered = pending[messageID] ?? PendingMessage(
            parts: Array(repeating: nil, count: total),
            expiresAt: now.addingTimeInterval(timeout)
        )
        buffered.parts[sequence] = payload
        pending[messageID] = buffered

        guard buffered.parts.allSatisfy({ $0 != nil }) else {
            return nil
        }

        pending[messageID] = nil
        return buffered.parts.compactMap { $0 }.reduce(into: Data(), { $0.append($1) })
    }
}

@MainActor
protocol FeishuWebSocketConnection: AnyObject {
    func setLifecycleEventHandler(_ handler: (@MainActor @Sendable (FeishuWebSocketLifecycleEvent) -> Void)?)
    func connect() async throws
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}

@MainActor
protocol FeishuWebSocketFactory {
    func makeConnection(url: URL) -> any FeishuWebSocketConnection
}

@MainActor
final class URLSessionFeishuWebSocketConnection: FeishuWebSocketConnection {
    private final class DelegateProxy: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        var onDidOpen: ((String?) -> Void)?
        var onDidClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
        var onDidCompleteWithError: ((Error?) -> Void)?

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocolName: String?
        ) {
            onDidOpen?(protocolName)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            onDidClose?(closeCode, reason)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            onDidCompleteWithError?(error)
        }
    }

    private let task: URLSessionWebSocketTask
    private let delegateProxy: DelegateProxy
    private let session: URLSession
    private var lifecycleEventHandler: (@MainActor @Sendable (FeishuWebSocketLifecycleEvent) -> Void)?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isConnected = false
    private var lastHandshakeHeaders: [String: String] = [:]
    private var lastHandshakeHTTPStatusCode: Int?

    init(url: URL) {
        let delegateProxy = DelegateProxy()
        let session = URLSession(configuration: .default, delegate: delegateProxy, delegateQueue: nil)
        self.delegateProxy = delegateProxy
        self.session = session
        self.task = session.webSocketTask(with: url)

        delegateProxy.onDidOpen = { [weak self] negotiatedProtocol in
            guard let self else { return }
            self.isConnected = true
            self.emitHandshakeResponseIfAvailable()
            Task { @MainActor in
                self.lifecycleEventHandler?(.didOpen(negotiatedProtocol: negotiatedProtocol))
            }
            self.connectContinuation?.resume()
            self.connectContinuation = nil
        }

        delegateProxy.onDidClose = { [weak self] closeCode, reasonData in
            guard let self else { return }
            self.isConnected = false
            let reason = reasonData.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                self.lifecycleEventHandler?(.didClose(code: Int(closeCode.rawValue), reason: reason))
            }
            if let connectContinuation = self.connectContinuation {
                connectContinuation.resume(throwing: URLError(.cannotConnectToHost))
                self.connectContinuation = nil
            }
        }

        delegateProxy.onDidCompleteWithError = { [weak self] error in
            guard let self, let error else { return }
            self.isConnected = false
            self.emitHandshakeResponseIfAvailable()
            if let connectContinuation = self.connectContinuation {
                connectContinuation.resume(throwing: self.mapHandshakeErrorIfPossible(fallback: error))
                self.connectContinuation = nil
            }
        }
    }

    func setLifecycleEventHandler(_ handler: (@MainActor @Sendable (FeishuWebSocketLifecycleEvent) -> Void)?) {
        lifecycleEventHandler = handler
    }

    func connect() async throws {
        task.resume()
        if isConnected {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
        }
    }

    func receive() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return Data()
        }
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func emitHandshakeResponseIfAvailable() {
        guard let response = task.response as? HTTPURLResponse else {
            return
        }
        let headers = normalizedHeaders(from: response)
        lastHandshakeHTTPStatusCode = response.statusCode
        lastHandshakeHeaders = headers
        Task { @MainActor in
            self.lifecycleEventHandler?(.didReceiveHandshakeResponse(httpStatusCode: response.statusCode, headers: headers))
        }
    }

    private func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value in
            guard let keyString = key as? String else { return nil }
            return (keyString.lowercased(), String(describing: value))
        })
    }

    private func mapHandshakeErrorIfPossible(fallback: Error) -> Error {
        let headers = lastHandshakeHeaders
        guard let handshakeStatusString = headers["handshake-status"],
              let handshakeStatus = Int(handshakeStatusString) else {
            return fallback
        }
        let authErrorCode = headers["handshake-autherrcode"].flatMap(Int.init)
        return FeishuWebSocketConnectionError.handshakeFailed(
            statusCode: handshakeStatus,
            message: headers["handshake-msg"],
            authErrorCode: authErrorCode
        )
    }
}

@MainActor
struct URLSessionFeishuWebSocketFactory: FeishuWebSocketFactory {
    func makeConnection(url: URL) -> any FeishuWebSocketConnection {
        URLSessionFeishuWebSocketConnection(url: url)
    }
}

@MainActor
final class FeishuLongConnectionEventSource: FeishuInboundEventSource {
    private static let endpointSystemBusyCode = 1
    private static let endpointInternalErrorCode = 1000040343

    enum EventSourceError: LocalizedError, Equatable {
        case invalidEndpointResponse
        case endpointRejected(code: Int, message: String)
        case missingConnectionURL
        case invalidEventPayload
        case connectionLimitExceeded
        case handshakeForbidden(message: String?)
        case handshakeAuthenticationFailed(message: String?, authErrorCode: Int?)
        case handshakeRejected(statusCode: Int, message: String?, authErrorCode: Int?)

        var errorDescription: String? {
            switch self {
            case .invalidEndpointResponse:
                return "飞书长连接 endpoint 响应不可解析"
            case .endpointRejected(let code, let message):
                return "飞书长连接 endpoint 错误 (\(code)): \(message)"
            case .missingConnectionURL:
                return "飞书长连接 endpoint 未返回连接地址"
            case .invalidEventPayload:
                return "飞书长连接事件 payload 无法解析"
            case .connectionLimitExceeded:
                return "飞书长连接已超过连接数限制"
            case .handshakeForbidden(let message):
                return "飞书长连接握手被拒绝: \(message ?? "forbidden")"
            case .handshakeAuthenticationFailed(let message, let authErrorCode):
                return "飞书长连接鉴权失败 (\(authErrorCode ?? -1)): \(message ?? "auth failed")"
            case .handshakeRejected(let statusCode, let message, let authErrorCode):
                return "飞书长连接握手失败 (status=\(statusCode), auth=\(authErrorCode ?? -1)): \(message ?? "unknown")"
            }
        }
    }

    private struct RuntimeState {
        let credentials: FeishuCredentials
        let onEvent: @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void
        let onCallback: @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    }

    private struct EndpointRequest: Encodable {
        let appID: String
        let appSecret: String

        enum CodingKeys: String, CodingKey {
            case appID = "AppID"
            case appSecret = "AppSecret"
        }
    }

    private struct EndpointResponse: Decodable {
        let code: Int
        let msg: String
        let data: EndpointData?
    }

    private struct EndpointData: Decodable {
        let url: String?
        let clientConfig: ClientConfig?

        enum CodingKeys: String, CodingKey {
            case url = "URL"
            case clientConfig = "ClientConfig"
        }
    }

    private struct ClientConfig: Decodable {
        let reconnectCount: Int?
        let reconnectInterval: Int?
        let reconnectNonce: Int?
        let pingInterval: Int?

        enum CodingKeys: String, CodingKey {
            case reconnectCount = "ReconnectCount"
            case reconnectInterval = "ReconnectInterval"
            case reconnectNonce = "ReconnectNonce"
            case pingInterval = "PingInterval"
        }
    }

    private struct AckResponse: Encodable {
        let code: Int
        let headers: [String: String]?
        let data: String?
    }

    private struct P2Envelope: Decodable {
        let schema: String?
        let header: Header
        let event: Event

        struct Header: Decodable {
            let eventType: String

            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
            }
        }

        struct Event: Decodable {
            let sender: Sender
            let message: Message
        }

        struct Sender: Decodable {
            let senderID: SenderID
            let senderType: String?
            let tenantKey: String?

            enum CodingKeys: String, CodingKey {
                case senderID = "sender_id"
                case senderType = "sender_type"
                case tenantKey = "tenant_key"
            }
        }

        struct SenderID: Decodable {
            let openID: String?
            let userID: String?
            let unionID: String?

            enum CodingKeys: String, CodingKey {
                case openID = "open_id"
                case userID = "user_id"
                case unionID = "union_id"
            }
        }

        struct Message: Decodable {
            let messageID: String
            let chatID: String
            let messageType: String
            let chatType: String
            let content: String
            let mentions: [Mention]?

            enum CodingKeys: String, CodingKey {
                case messageID = "message_id"
                case chatID = "chat_id"
                case messageType = "message_type"
                case chatType = "chat_type"
                case content
                case mentions
            }
        }

        struct Mention: Decodable {
            let key: String?
            let id: SenderID?
            let name: String?
            let tenantKey: String?

            enum CodingKeys: String, CodingKey {
                case key
                case id
                case name
                case tenantKey = "tenant_key"
            }
        }
    }

    private struct GenericP2Envelope: Decodable {
        let schema: String?
        let header: Header

        struct Header: Decodable {
            let eventType: String

            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
            }
        }
    }

    private enum EventPayloadDisposition {
        case supported(FeishuEventEnvelope)
        case unsupported(eventType: String)
    }

    private let transport: any FeishuTransport
    private let socketFactory: any FeishuWebSocketFactory
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let frameCodec: FeishuWSFrameCodec
    private let assembler: FeishuMultipartAssembler
    private let connectionStatusStore: FeishuChannelConnectionStatusStore
    private let nowProvider: () -> Date
    private let sleep: (UInt64) async throws -> Void
    private let reconnectJitterProvider: (UInt64) -> UInt64
    private let debugLogger: @Sendable (String) -> Void
    private var connection: (any FeishuWebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var serviceID: Int32 = 0
    private var pingIntervalSeconds: Int = 120
    private var reconnectCount: Int = 10
    private var reconnectIntervalSeconds: Int = 120
    private var reconnectNonceSeconds: Int = 30
    private var runtimeState: RuntimeState?
    private var isStopping = false

    init(
        transport: any FeishuTransport,
        socketFactory: (any FeishuWebSocketFactory)? = nil,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        frameCodec: FeishuWSFrameCodec? = nil,
        assembler: FeishuMultipartAssembler? = nil,
        connectionStatusStore: FeishuChannelConnectionStatusStore = .shared,
        nowProvider: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        reconnectJitterProvider: @escaping (UInt64) -> UInt64 = { upperBound in
            guard upperBound > 0 else { return 0 }
            return UInt64.random(in: 0..<upperBound)
        },
        debugLogger: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.transport = transport
        self.socketFactory = socketFactory ?? URLSessionFeishuWebSocketFactory()
        self.decoder = decoder
        self.encoder = encoder
        self.frameCodec = frameCodec ?? FeishuWSFrameCodec()
        self.assembler = assembler ?? FeishuMultipartAssembler()
        self.connectionStatusStore = connectionStatusStore
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.reconnectJitterProvider = reconnectJitterProvider
        self.debugLogger = debugLogger
    }

    func start(
        credentials: FeishuCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws {
        _ = tokenProvider
        debugLog("start long connection app_id=\(credentials.appID)")
        runtimeState = RuntimeState(credentials: credentials, onEvent: onEvent, onCallback: onCallback)
        isStopping = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionStatusStore.reportConnecting()
        do {
            try await establishConnection(credentials: credentials)
        } catch {
            do {
                try await reconnectUntilConnected(runtimeState: RuntimeState(credentials: credentials, onEvent: onEvent, onCallback: onCallback), initialError: error)
            } catch {
                debugLog("start failed error=\(error.localizedDescription)")
                connectionStatusStore.reportFailure(error.localizedDescription)
                throw error
            }
        }
        receiveTask?.cancel()
        pingTask?.cancel()
        launchRuntimeTasks(onEvent: onEvent, onCallback: onCallback)
    }

    func stop() async {
        debugLog("stop long connection")
        isStopping = true
        receiveTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        receiveTask = nil
        pingTask = nil
        reconnectTask = nil
        if let connection {
            await connection.close()
        }
        connection = nil
        runtimeState = nil
        connectionStatusStore.reportStopped()
    }

    private func fetchConnectionEndpoint(credentials: FeishuCredentials) async throws -> (URL, ClientConfig?) {
        let url = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "locale")
        request.httpBody = try encoder.encode(EndpointRequest(appID: credentials.appID, appSecret: credentials.appSecret))
        debugLog("fetch endpoint request url=\(url.absoluteString) app_id=\(credentials.appID)")
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            debugLog("fetch endpoint invalid http response")
            throw EventSourceError.invalidEndpointResponse
        }
        debugLog("fetch endpoint response status=\(httpResponse.statusCode) bytes=\(data.count)")
        let payload = try decoder.decode(EndpointResponse.self, from: data)
        guard payload.code == 0 else {
            debugLog("fetch endpoint rejected code=\(payload.code) msg=\(payload.msg)")
            throw EventSourceError.endpointRejected(code: payload.code, message: payload.msg)
        }
        guard let rawURL = payload.data?.url, let resolved = URL(string: rawURL) else {
            debugLog("fetch endpoint missing URL in payload")
            throw EventSourceError.missingConnectionURL
        }
        debugLog("fetch endpoint succeeded websocket_url=\(resolved.absoluteString)")
        return (resolved, payload.data?.clientConfig)
    }

    private func apply(clientConfig: ClientConfig?) {
        guard let clientConfig else { return }
        if let reconnectCount = clientConfig.reconnectCount {
            self.reconnectCount = reconnectCount
        }
        if let reconnectInterval = clientConfig.reconnectInterval, reconnectInterval > 0 {
            reconnectIntervalSeconds = reconnectInterval
        }
        if let reconnectNonce = clientConfig.reconnectNonce, reconnectNonce >= 0 {
            reconnectNonceSeconds = reconnectNonce
        }
        if let pingInterval = clientConfig.pingInterval, pingInterval > 0 {
            pingIntervalSeconds = pingInterval
        }
    }

    private func establishConnection(credentials: FeishuCredentials) async throws {
        let (url, config) = try await fetchConnectionEndpoint(credentials: credentials)
        apply(clientConfig: config)
        serviceID = Int32(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "service_id" })?
            .value.flatMap(Int.init) ?? 0)
        debugLog("connect websocket url=\(url.absoluteString) service_id=\(serviceID)")
        let connection = socketFactory.makeConnection(url: url)
        debugLog("connect websocket created connection instance")
        connection.setLifecycleEventHandler { [weak self] event in
            self?.handleLifecycleEvent(event)
        }
        do {
            try await connection.connect()
        } catch {
            debugLog("connect websocket failed error=\(error.localizedDescription)")
            throw mapConnectionError(error)
        }
        self.connection = connection
        connectionStatusStore.reportConnected(url: url, serviceID: serviceID, at: nowProvider())
        debugLog("connect websocket succeeded")
    }

    private func launchRuntimeTasks(
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) {
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop(onEvent: onEvent, onCallback: onCallback)
        }
        pingTask = Task { [weak self] in
            await self?.runPingLoop()
        }
    }

    private func runReceiveLoop(
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async {
        guard let connection else { return }
        while !Task.isCancelled {
            do {
                let data = try await connection.receive()
                let frame = try frameCodec.decode(data)
                debugLog("received frame method=\(frame.method.rawValue) headers=\(frame.headerMap)")
                try await handle(frame: frame, onEvent: onEvent, onCallback: onCallback)
            } catch is CancellationError {
                return
            } catch {
                debugLog("receive loop failed error=\(error.localizedDescription)")
                await handleRuntimeFailure(error)
                return
            }
        }
    }

    private func runPingLoop() async {
        while !Task.isCancelled {
            do {
                try await sleep(UInt64(max(1, pingIntervalSeconds)) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                try await sendPing()
            } catch is CancellationError {
                return
            } catch {
                debugLog("ping loop failed error=\(error.localizedDescription)")
                await handleRuntimeFailure(error)
                return
            }
        }
    }

    private func handleRuntimeFailure(_ error: Error) async {
        guard !isStopping, reconnectTask == nil, let runtimeState else { return }
        await closeCurrentConnectionForReconnect()
        debugLog("runtime failure scheduling reconnect error=\(error.localizedDescription)")
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(runtimeState: runtimeState, initialError: error)
        }
    }

    private func runReconnectLoop(runtimeState: RuntimeState, initialError: Error) async {
        do {
            try await reconnectUntilConnected(runtimeState: runtimeState, initialError: initialError)
            launchRuntimeTasks(onEvent: runtimeState.onEvent, onCallback: runtimeState.onCallback)
        } catch is CancellationError {
        } catch {
            connectionStatusStore.reportFailure(error.localizedDescription)
        }
        reconnectTask = nil
    }

    private func reconnectUntilConnected(runtimeState: RuntimeState, initialError: Error) async throws {
        var lastError = initialError
        var attempt = 0
        while !Task.isCancelled, !isStopping {
            if !isRetryableError(lastError) {
                throw lastError
            }
            if reconnectCount >= 0, attempt >= reconnectCount {
                throw lastError
            }

            debugLog("reconnect attempt=\(attempt + 1) last_error=\(lastError.localizedDescription)")
            connectionStatusStore.reportReconnecting(lastError.localizedDescription)
            if attempt == 0, reconnectNonceSeconds > 0 {
                let jitter = reconnectJitterProvider(UInt64(reconnectNonceSeconds))
                if jitter > 0 {
                    debugLog("reconnect jitter_seconds=\(jitter)")
                    try await sleep(jitter * 1_000_000_000)
                }
            } else {
                debugLog("reconnect sleep_seconds=\(max(1, reconnectIntervalSeconds))")
                try await sleep(UInt64(max(1, reconnectIntervalSeconds)) * 1_000_000_000)
            }
            guard !isStopping else {
                throw CancellationError()
            }

            do {
                try await establishConnection(credentials: runtimeState.credentials)
                debugLog("reconnect succeeded on attempt=\(attempt + 1)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                debugLog("reconnect attempt failed error=\(error.localizedDescription)")
                lastError = error
                attempt += 1
            }
        }

        throw CancellationError()
    }

    private func closeCurrentConnectionForReconnect() async {
        receiveTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        pingTask = nil
        guard let connection else { return }
        self.connection = nil
        await connection.close()
    }

    private func sendPing() async throws {
        guard let connection else { return }
        let frame = FeishuWSFrame(
            seqID: 0,
            logID: 0,
            service: serviceID,
            method: .control,
            headers: [.init(key: "type", value: "ping")],
            payloadEncoding: nil,
            payloadType: nil,
            payload: nil,
            logIDNew: nil
        )
        debugLog("send ping service_id=\(serviceID)")
        try await connection.send(try frameCodec.encode(frame))
    }

    private func mapConnectionError(_ error: Error) -> Error {
        guard let error = error as? FeishuWebSocketConnectionError else {
            return error
        }
        switch error {
        case .handshakeFailed(let statusCode, let message, let authErrorCode):
            if statusCode == 514, authErrorCode == 1000040350 {
                return EventSourceError.connectionLimitExceeded
            }
            if statusCode == 514 {
                return EventSourceError.handshakeAuthenticationFailed(message: message, authErrorCode: authErrorCode)
            }
            if statusCode == 403 {
                return EventSourceError.handshakeForbidden(message: message)
            }
            return EventSourceError.handshakeRejected(statusCode: statusCode, message: message, authErrorCode: authErrorCode)
        }
    }

    private func handleLifecycleEvent(_ event: FeishuWebSocketLifecycleEvent) {
        switch event {
        case .didReceiveHandshakeResponse(let httpStatusCode, let headers):
            debugLog("handshake response http_status=\(httpStatusCode) headers=\(headers)")
            connectionStatusStore.reportHandshakeResponse(httpStatusCode: httpStatusCode, headers: headers)
        case .didOpen(let negotiatedProtocol):
            debugLog("websocket opened negotiated_protocol=\(negotiatedProtocol ?? "nil")")
            connectionStatusStore.reportSocketOpened(protocol: negotiatedProtocol)
        case .didClose(let code, let reason):
            debugLog("websocket closed code=\(code) reason=\(reason ?? "nil")")
            connectionStatusStore.reportSocketClosed(code: code, reason: reason)
        }
    }

    private func isRetryableError(_ error: Error) -> Bool {
        switch error {
        case EventSourceError.connectionLimitExceeded,
             EventSourceError.handshakeForbidden:
            return false
        case EventSourceError.handshakeAuthenticationFailed,
             EventSourceError.handshakeRejected:
            return true
        case EventSourceError.endpointRejected(let code, _):
            return code == Self.endpointSystemBusyCode || code == Self.endpointInternalErrorCode
        default:
            return true
        }
    }

    private func handle(
        frame: FeishuWSFrame,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws {
        switch frame.method {
        case .control:
            try handleControlFrame(frame)
        case .data:
            try await handleDataFrame(frame, onEvent: onEvent, onCallback: onCallback)
        }
    }

    private func handleControlFrame(_ frame: FeishuWSFrame) throws {
        let type = frame.headerMap["type"]
        guard type == "pong", let payload = frame.payload, !payload.isEmpty else {
            return
        }
        let config = try decoder.decode(ClientConfig.self, from: payload)
        apply(clientConfig: config)
    }

    private func handleDataFrame(
        _ frame: FeishuWSFrame,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void,
        onCallback: @escaping @MainActor @Sendable (FeishuCallbackEnvelope) async throws -> Data?
    ) async throws {
        let headers = frame.headerMap
        let type = headers["type"] ?? "event"
        guard let payload = assembler.append(frame: frame, now: nowProvider()) else {
            debugLog("buffer multipart frame type=\(type) message_id=\(headers["message_id"] ?? "nil")")
            return
        }

        let startedAt = nowProvider()
        connectionStatusStore.reportEventReceived(at: startedAt)
        debugLog("handle data frame type=\(type) message_id=\(headers["message_id"] ?? "nil") trace_id=\(headers["trace_id"] ?? "nil") payload_bytes=\(payload.count)")
        switch type {
        case "event":
            do {
                switch try decodeEventPayload(from: payload) {
                case .supported(let envelope):
                    try await onEvent(envelope)
                case .unsupported(let eventType):
                    debugLog("ignore unsupported event type=\(eventType) message_id=\(headers["message_id"] ?? "nil") trace_id=\(headers["trace_id"] ?? "nil") payload_prefix=\(payloadPreview(from: payload))")
                }
                try await sendAck(for: frame, code: 200, startedAt: startedAt, responseData: nil)
            } catch {
                debugLog("event handling failed message_id=\(headers["message_id"] ?? "nil") trace_id=\(headers["trace_id"] ?? "nil") error=\(error.localizedDescription) payload_prefix=\(payloadPreview(from: payload))")
                try await sendAck(for: frame, code: 500, startedAt: startedAt, responseData: nil)
            }
        default:
            do {
                let responseData = try await onCallback(
                    FeishuCallbackEnvelope(messageType: type, payload: payload, headers: headers)
                )
                try await sendAck(for: frame, code: 200, startedAt: startedAt, responseData: responseData)
            } catch {
                debugLog("callback handling failed type=\(type) message_id=\(headers["message_id"] ?? "nil") trace_id=\(headers["trace_id"] ?? "nil") error=\(error.localizedDescription) payload_prefix=\(payloadPreview(from: payload))")
                try await sendAck(for: frame, code: 500, startedAt: startedAt, responseData: nil)
            }
        }
    }

    private func decodeEventPayload(from payload: Data) throws -> EventPayloadDisposition {
        let genericEnvelope = try decoder.decode(GenericP2Envelope.self, from: payload)
        guard genericEnvelope.header.eventType == "im.message.receive_v1" else {
            return .unsupported(eventType: genericEnvelope.header.eventType)
        }

        let p2Envelope = try decoder.decode(P2Envelope.self, from: payload)
        guard let openID = p2Envelope.event.sender.senderID.openID else {
            throw EventSourceError.invalidEventPayload
        }
        let senderID = FeishuEventEnvelope.SenderID(
            openID: openID,
            userID: p2Envelope.event.sender.senderID.userID,
            unionID: p2Envelope.event.sender.senderID.unionID
        )
        let mentions: [FeishuEventEnvelope.Mention] = (p2Envelope.event.message.mentions ?? []).map { mention in
            FeishuEventEnvelope.Mention(
                key: mention.key,
                id: mention.id.map {
                    FeishuEventEnvelope.SenderID(openID: $0.openID, userID: $0.userID, unionID: $0.unionID)
                },
                name: mention.name,
                tenantKey: mention.tenantKey
            )
        }
        return .supported(FeishuEventEnvelope(
            header: FeishuEventEnvelope.Header(eventType: p2Envelope.header.eventType),
            event: FeishuEventEnvelope.Event(
                sender: FeishuEventEnvelope.Sender(
                    senderID: senderID,
                    senderType: p2Envelope.event.sender.senderType,
                    tenantKey: p2Envelope.event.sender.tenantKey
                ),
                message: FeishuEventEnvelope.Message(
                    messageID: p2Envelope.event.message.messageID,
                    chatID: p2Envelope.event.message.chatID,
                    messageType: p2Envelope.event.message.messageType,
                    chatType: p2Envelope.event.message.chatType,
                    content: p2Envelope.event.message.content,
                    mentions: mentions
                )
            )
        ))
    }

    private func sendAck(
        for originalFrame: FeishuWSFrame,
        code: Int,
        startedAt: Date,
        responseData: Data?
    ) async throws {
        guard let connection else { return }
        let elapsed = max(0, Int(nowProvider().timeIntervalSince(startedAt) * 1000))
        var headers = originalFrame.headers.filter { $0.key != "biz_rt" }
        headers.append(.init(key: "biz_rt", value: String(elapsed)))
        let payload = try encoder.encode(
            AckResponse(
                code: code,
                headers: nil,
                data: responseData?.base64EncodedString()
            )
        )
        let ackFrame = FeishuWSFrame(
            seqID: originalFrame.seqID,
            logID: originalFrame.logID,
            service: originalFrame.service,
            method: originalFrame.method,
            headers: headers,
            payloadEncoding: originalFrame.payloadEncoding,
            payloadType: originalFrame.payloadType,
            payload: payload,
            logIDNew: originalFrame.logIDNew
        )
        debugLog("send ack code=\(code) message_id=\(originalFrame.headerMap["message_id"] ?? "nil") biz_rt_ms=\(elapsed) data_bytes=\(responseData?.count ?? 0)")
        try await connection.send(try frameCodec.encode(ackFrame))
    }

    private func debugLog(_ message: String) {
        debugLogger("[feishu-long-connection] \(message)")
    }

    private func payloadPreview(from payload: Data, maxLength: Int = 160) -> String {
        let prefix = payload.prefix(maxLength)
        var preview = String(decoding: prefix, as: UTF8.self)
        preview = preview.replacingOccurrences(of: "\n", with: "\\n")
        return preview
    }
}