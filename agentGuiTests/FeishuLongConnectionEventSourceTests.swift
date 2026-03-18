import Foundation
import Testing
@testable import agentGui

@MainActor
struct FeishuLongConnectionEventSourceTests {
    @Test func eventSourceEmitsDebugLogsForEndpointAndConnectionLifecycle() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        var logs: [String] = []
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: RecordingFeishuWebSocketConnection(incomingMessages: [])),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() },
            debugLogger: { logs.append($0) }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }

        #expect(logs.contains(where: { $0.contains("start long connection app_id=cli_test") }))
        #expect(logs.contains(where: { $0.contains("fetch endpoint request url=https://open.feishu.cn/callback/ws/endpoint") }))
        #expect(logs.contains(where: { $0.contains("connect websocket url=wss://ws.example.com/path?device_id=device-1&service_id=42 service_id=42") }))
        #expect(logs.contains(where: { $0.contains("websocket opened") }))
    }

    @Test func frameCodecRoundTripsHeadersAndPayload() throws {
        let frame = FeishuWSFrame(
            seqID: 1,
            logID: 2,
            service: 3,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-1")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: Data("hello".utf8),
            logIDNew: nil
        )

        let encoded = try FeishuWSFrameCodec().encode(frame)
        let decoded = try FeishuWSFrameCodec().decode(encoded)

        #expect(decoded.seqID == 1)
        #expect(decoded.logID == 2)
        #expect(decoded.service == 3)
        #expect(decoded.method == .data)
        #expect(decoded.headers == frame.headers)
        #expect(decoded.payload == Data("hello".utf8))
    }

    @Test func multipartAssemblerCombinesSplitPayloadByMessageID() throws {
        let assembler = FeishuMultipartAssembler()
        let part0 = FeishuWSFrame(
            seqID: 0,
            logID: 0,
            service: 0,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-1"),
                .init(key: "sum", value: "2"),
                .init(key: "seq", value: "0")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: Data("hel".utf8),
            logIDNew: nil
        )
        let part1 = FeishuWSFrame(
            seqID: 0,
            logID: 0,
            service: 0,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-1"),
                .init(key: "sum", value: "2"),
                .init(key: "seq", value: "1")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: Data("lo".utf8),
            logIDNew: nil
        )

        let first = assembler.append(frame: part0, now: Date(timeIntervalSince1970: 0))
        let second = assembler.append(frame: part1, now: Date(timeIntervalSince1970: 0))

        #expect(first == nil)
        #expect(second == Data("hello".utf8))
    }

    @Test func eventSourceFetchesEndpointAndConnectsWebSocket() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [])
        let factory = RecordingFeishuWebSocketFactory(connection: socket)
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: factory,
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }

        #expect(transport.requests.count == 1)
        let endpointRequest = try #require(transport.requests.first)
        #expect(endpointRequest.url?.path == "/callback/ws/endpoint")
        #expect(endpointRequest.value(forHTTPHeaderField: "locale") == "zh")
        #expect(factory.connectedURL?.absoluteString == "wss://ws.example.com/path?device_id=device-1&service_id=42")
        #expect(socket.connectCallCount == 1)
    }

    @Test func eventSourceAcknowledgesAndForwardsReceiveMessageEvent() async throws {
        let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        let wsURL = URL(string: "wss://ws.example.com/path?device_id=device-1&service_id=42")!
        let payload = Data(
            """
            {"schema":"2.0","header":{"event_id":"evt-1","event_type":"im.message.receive_v1","create_time":"1710000000000","token":"token-1","app_id":"cli_test","tenant_key":"tenant-1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"},"sender_type":"user","tenant_key":"tenant-1"},"message":{"message_id":"om_test_message","chat_id":"oc_test_chat","chat_type":"p2p","message_type":"text","content":"{\\\"text\\\":\\\"你好\\\"}"}}}
            """.utf8
        )
        let incomingFrame = FeishuWSFrame(
            seqID: 7,
            logID: 11,
            service: 42,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-1"),
                .init(key: "trace_id", value: "trace-1"),
                .init(key: "sum", value: "1"),
                .init(key: "seq", value: "0")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: payload,
            logIDNew: nil
        )
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(
            incomingMessages: [try FeishuWSFrameCodec().encode(incomingFrame)]
        )
        let factory = RecordingFeishuWebSocketFactory(connection: socket)
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: factory,
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )
        var received: [FeishuEventEnvelope] = []

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { event in
            received.append(event)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(received.count == 1)
        #expect(received.first?.header.eventType == "im.message.receive_v1")
        #expect(received.first?.event.message.messageID == "om_test_message")
        #expect(received.first?.event.sender.senderID.openID == "ou_test_user")

        let ackData = try #require(socket.sentMessages.first)
        let ackFrame = try FeishuWSFrameCodec().decode(ackData)
        #expect(ackFrame.seqID == 7)
        #expect(ackFrame.logID == 11)
        #expect(ackFrame.headers.contains(where: { $0.key == "biz_rt" }))
        let ackPayload = String(data: try #require(ackFrame.payload), encoding: .utf8) ?? ""
        #expect(ackPayload.contains("\"code\":200"))
        #expect(factory.connectedURL == wsURL)
    }

    @Test func eventSourceBase64EncodesCallbackAckDataForCardFrames() async throws {
        let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        let callbackPayload = Data("{\"action\":\"clicked\"}".utf8)
        let incomingFrame = FeishuWSFrame(
            seqID: 9,
            logID: 13,
            service: 42,
            method: .data,
            headers: [
                .init(key: "type", value: "card"),
                .init(key: "message_id", value: "msg-card-1"),
                .init(key: "trace_id", value: "trace-card-1"),
                .init(key: "sum", value: "1"),
                .init(key: "seq", value: "0")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: callbackPayload,
            logIDNew: nil
        )
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [try FeishuWSFrameCodec().encode(incomingFrame)])
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )

        try await source.start(
            credentials: .init(appID: "cli_test", appSecret: "secret_test"),
            tokenProvider: { "unused" },
            onEvent: { _ in },
            onCallback: { envelope in
                #expect(envelope.messageType == "card")
                #expect(envelope.payload == callbackPayload)
                return Data("{\"toast\":{\"type\":\"success\"}}".utf8)
            }
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        let ackData = try #require(socket.sentMessages.first)
        let ackFrame = try FeishuWSFrameCodec().decode(ackData)
        let ackPayload = try #require(ackFrame.payload)
        let ackResponse = try JSONDecoder().decode(FeishuAckResponseFixture.self, from: ackPayload)
        #expect(ackResponse.code == 200)
        #expect(ackResponse.data == Data("{\"toast\":{\"type\":\"success\"}}".utf8).base64EncodedString())
    }

    @Test func eventSourceReportsConnectedStateToStatusStore() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let store = FeishuChannelConnectionStatusStore()
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: RecordingFeishuWebSocketConnection(incomingMessages: [])),
            connectionStatusStore: store,
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }

        #expect(store.phase == .connected)
        #expect(store.serviceID == 42)
        #expect(store.connectedURL?.absoluteString.contains("device_id=device-1") == true)
        #expect(store.lastHandshakeHTTPStatus == nil)
        #expect(store.lastHandshakeStatus == nil)
        #expect(store.lastHandshakeMessage == nil)
        #expect(store.lastHandshakeAuthErrorCode == nil)
    }

    @Test func eventSourceReportsLastErrorToStatusStoreOnHandshakeFailure() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [])
        socket.connectError = FeishuWebSocketConnectionError.handshakeFailed(
            statusCode: 403,
            message: "forbidden",
            authErrorCode: nil
        )
        let store = FeishuChannelConnectionStatusStore()
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            connectionStatusStore: store,
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )

        await #expect(throws: FeishuLongConnectionEventSource.EventSourceError.handshakeForbidden(message: "forbidden")) {
            try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }
        }

        #expect(store.phase == .failed)
        #expect(store.lastErrorMessage == "飞书长连接握手被拒绝: forbidden")
        #expect(store.lastHandshakeHTTPStatus == 101)
        #expect(store.lastHandshakeStatus == 403)
        #expect(store.lastHandshakeMessage == "forbidden")
    }

    @Test func eventSourceClassifiesHandshakeConnectionLimitErrors() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [])
        socket.connectError = FeishuWebSocketConnectionError.handshakeFailed(
            statusCode: 514,
            message: "too many connections",
            authErrorCode: 1000040350
        )
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() }
        )

        await #expect(throws: FeishuLongConnectionEventSource.EventSourceError.connectionLimitExceeded) {
            try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }
        }
    }

    @Test func eventSourceReconnectsAfterReceiveFailure() async throws {
        let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        let payload = Data(
            """
            {"schema":"2.0","header":{"event_id":"evt-2","event_type":"im.message.receive_v1","create_time":"1710000000000","token":"token-1","app_id":"cli_test","tenant_key":"tenant-1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"},"sender_type":"user","tenant_key":"tenant-1"},"message":{"message_id":"om_test_message_2","chat_id":"oc_test_chat","chat_type":"p2p","message_type":"text","content":"{\\\"text\\\":\\\"重连成功\\\"}"}}}
            """.utf8
        )
        let firstConnection = RecordingFeishuWebSocketConnection(incomingMessages: [])
        firstConnection.receiveError = URLError(.networkConnectionLost)
        let secondConnection = RecordingFeishuWebSocketConnection(
            incomingMessages: [try FeishuWSFrameCodec().encode(
                FeishuWSFrame(
                    seqID: 8,
                    logID: 12,
                    service: 42,
                    method: .data,
                    headers: [
                        .init(key: "type", value: "event"),
                        .init(key: "message_id", value: "msg-2"),
                        .init(key: "trace_id", value: "trace-2"),
                        .init(key: "sum", value: "1"),
                        .init(key: "seq", value: "0")
                    ],
                    payloadEncoding: nil,
                    payloadType: nil,
                    payload: payload,
                    logIDNew: nil
                )
            )]
        )
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":2,"ReconnectInterval":1,"ReconnectNonce":0,"PingInterval":120}}}
                """
            ),
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-2&service_id=42","ClientConfig":{"ReconnectCount":2,"ReconnectInterval":1,"ReconnectNonce":0,"PingInterval":120}}}
                """
            )
        ])
        let factory = SequencedFeishuWebSocketFactory(connections: [firstConnection, secondConnection])
        var sleptDurations: [UInt64] = []
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: factory,
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { duration in
                sleptDurations.append(duration)
                if duration == 1_000_000_000 {
                    return
                }
                throw CancellationError()
            },
            reconnectJitterProvider: { _ in 0 }
        )
        var received: [FeishuEventEnvelope] = []

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { event in
            received.append(event)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(factory.makeConnectionCallCount == 2)
        #expect(received.count == 1)
        #expect(received.first?.event.message.messageID == "om_test_message_2")
        #expect(sleptDurations.contains(1_000_000_000))
        #expect(firstConnection.closeCallCount == 1)
        #expect(firstConnection.sentMessages.isEmpty)
    }

    @Test func eventSourceRetriesInitialHandshakeServerFailure() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":2,"ReconnectInterval":1,"ReconnectNonce":0,"PingInterval":120}}}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-2&service_id=42","ClientConfig":{"ReconnectCount":2,"ReconnectInterval":1,"ReconnectNonce":0,"PingInterval":120}}}
                """
            )
        ])
        let firstConnection = RecordingFeishuWebSocketConnection(incomingMessages: [])
        firstConnection.connectError = FeishuWebSocketConnectionError.handshakeFailed(
            statusCode: 514,
            message: "auth failed",
            authErrorCode: 1000040001
        )
        let secondConnection = RecordingFeishuWebSocketConnection(incomingMessages: [])
        var sleptDurations: [UInt64] = []
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: SequencedFeishuWebSocketFactory(connections: [firstConnection, secondConnection]),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { duration in
                sleptDurations.append(duration)
                if duration == 1_000_000_000 {
                    return
                }
                throw CancellationError()
            },
            reconnectJitterProvider: { _ in 0 }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }

        #expect(secondConnection.connectCallCount == 1)
        #expect(sleptDurations.contains(1_000_000_000))
    }

    @Test func eventSourceRetriesInitialEndpointServerBusyFailure() async throws {
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":1,"msg":"system busy","data":null}
                """
            ),
            .json(
                url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-2&service_id=42","ClientConfig":{"ReconnectCount":2,"ReconnectInterval":1,"ReconnectNonce":0,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [])
        var sleptDurations: [UInt64] = []
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { duration in
                sleptDurations.append(duration)
                if duration == 1_000_000_000 {
                    return
                }
                throw CancellationError()
            },
            reconnectJitterProvider: { _ in 0 }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }

        #expect(transport.requests.count == 2)
        #expect(socket.connectCallCount == 1)
        #expect(sleptDurations.isEmpty)
    }

    @Test func eventSourceAcknowledgesUnsupportedEventsAndLogsContext() async throws {
        let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        let payload = Data(
            """
            {"schema":"2.0","header":{"event_type":"contact.user.deleted_v1"},"event":{}}
            """.utf8
        )
        let incomingFrame = FeishuWSFrame(
            seqID: 10,
            logID: 14,
            service: 42,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-unsupported-1"),
                .init(key: "trace_id", value: "trace-unsupported-1"),
                .init(key: "sum", value: "1"),
                .init(key: "seq", value: "0")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: payload,
            logIDNew: nil
        )
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [try FeishuWSFrameCodec().encode(incomingFrame)])
        var logs: [String] = []
        var receivedCount = 0
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() },
            debugLogger: { logs.append($0) }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in
            receivedCount += 1
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(receivedCount == 0)
        let ackData = try #require(socket.sentMessages.first)
        let ackFrame = try FeishuWSFrameCodec().decode(ackData)
        let ackPayload = String(data: try #require(ackFrame.payload), encoding: .utf8) ?? ""
        #expect(ackPayload.contains("\"code\":200"))
        #expect(logs.contains(where: { $0.contains("ignore unsupported event type=contact.user.deleted_v1") && $0.contains("message_id=msg-unsupported-1") && $0.contains("trace_id=trace-unsupported-1") }))
    }

    @Test func eventSourceLogsPayloadContextForInvalidSupportedEvents() async throws {
        let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!
        let payload = Data(
            """
            {"schema":"2.0","header":{"event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{}},"message":{"message_id":"om_bad","chat_id":"oc_bad","chat_type":"p2p","message_type":"text","content":"{}"}}}
            """.utf8
        )
        let incomingFrame = FeishuWSFrame(
            seqID: 11,
            logID: 15,
            service: 42,
            method: .data,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "msg-invalid-1"),
                .init(key: "trace_id", value: "trace-invalid-1"),
                .init(key: "sum", value: "1"),
                .init(key: "seq", value: "0")
            ],
            payloadEncoding: nil,
            payloadType: nil,
            payload: payload,
            logIDNew: nil
        )
        let transport = RecordingFeishuTransport(responses: [
            .json(
                url: endpointURL,
                body: """
                {"code":0,"msg":"success","data":{"URL":"wss://ws.example.com/path?device_id=device-1&service_id=42","ClientConfig":{"ReconnectCount":10,"ReconnectInterval":120,"ReconnectNonce":30,"PingInterval":120}}}
                """
            )
        ])
        let socket = RecordingFeishuWebSocketConnection(incomingMessages: [try FeishuWSFrameCodec().encode(incomingFrame)])
        var logs: [String] = []
        let source = FeishuLongConnectionEventSource(
            transport: transport,
            socketFactory: RecordingFeishuWebSocketFactory(connection: socket),
            nowProvider: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in throw CancellationError() },
            debugLogger: { logs.append($0) }
        )

        try await source.start(credentials: .init(appID: "cli_test", appSecret: "secret_test"), tokenProvider: { "unused" }) { _ in }
        try await Task.sleep(nanoseconds: 20_000_000)

        let ackData = try #require(socket.sentMessages.first)
        let ackFrame = try FeishuWSFrameCodec().decode(ackData)
        let ackPayload = String(data: try #require(ackFrame.payload), encoding: .utf8) ?? ""
        #expect(ackPayload.contains("\"code\":500"))
        #expect(logs.contains(where: { $0.contains("event handling failed") && $0.contains("message_id=msg-invalid-1") && $0.contains("trace_id=trace-invalid-1") && $0.contains("payload_prefix=") }))
    }
}

private struct FeishuAckResponseFixture: Decodable {
    let code: Int
    let data: String?
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
                response: HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json; charset=utf-8"]
                )!
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
private final class RecordingFeishuWebSocketFactory: FeishuWebSocketFactory {
    private let connection: RecordingFeishuWebSocketConnection
    private(set) var connectedURL: URL?

    init(connection: RecordingFeishuWebSocketConnection) {
        self.connection = connection
    }

    func makeConnection(url: URL) -> any FeishuWebSocketConnection {
        connectedURL = url
        return connection
    }
}

@MainActor
private final class SequencedFeishuWebSocketFactory: FeishuWebSocketFactory {
    private var connections: [RecordingFeishuWebSocketConnection]
    private(set) var makeConnectionCallCount = 0

    init(connections: [RecordingFeishuWebSocketConnection]) {
        self.connections = connections
    }

    func makeConnection(url: URL) -> any FeishuWebSocketConnection {
        _ = url
        makeConnectionCallCount += 1
        return connections.removeFirst()
    }
}

@MainActor
private final class RecordingFeishuWebSocketConnection: FeishuWebSocketConnection {
    private var incomingMessages: [Data]
    var connectError: Error?
    var receiveError: Error?
    private var lifecycleEventHandler: (@MainActor @Sendable (FeishuWebSocketLifecycleEvent) -> Void)?
    private(set) var sentMessages: [Data] = []
    private(set) var connectCallCount = 0
    private(set) var closeCallCount = 0

    init(incomingMessages: [Data]) {
        self.incomingMessages = incomingMessages
    }

    func setLifecycleEventHandler(_ handler: (@MainActor @Sendable (FeishuWebSocketLifecycleEvent) -> Void)?) {
        lifecycleEventHandler = handler
    }

    func connect() async throws {
        connectCallCount += 1
        lifecycleEventHandler?(.didReceiveHandshakeResponse(
            httpStatusCode: 101,
            headers: [
                "handshake-status": connectError == nil ? "514" : "403",
                "handshake-msg": connectError == nil ? "auth failed" : "forbidden",
                "handshake-autherrcode": connectError == nil ? "1000040350" : ""
            ]
        ))
        if let connectError {
            throw connectError
        }
        lifecycleEventHandler?(.didOpen(negotiatedProtocol: nil))
    }

    func receive() async throws -> Data {
        if let receiveError {
            self.receiveError = nil
            throw receiveError
        }
        guard !incomingMessages.isEmpty else {
            throw CancellationError()
        }
        return incomingMessages.removeFirst()
    }

    func send(_ data: Data) async throws {
        sentMessages.append(data)
    }

    func close() async {
        closeCallCount += 1
        lifecycleEventHandler?(.didClose(code: URLSessionWebSocketTask.CloseCode.normalClosure.rawValue, reason: nil))
    }
}