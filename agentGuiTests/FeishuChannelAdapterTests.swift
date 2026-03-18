import Foundation
import Testing
@testable import agentGui

@MainActor
struct FeishuChannelAdapterTests {
    @Test func adapterLoadsCredentialsOnStart() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")

        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { _ in })

        #expect(client.startedCredentials == FeishuCredentials(appID: "cli_test", appSecret: "secret_test"))
    }

    @Test func adapterForwardsInboundMessageToHandler() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        var receivedMessages: [InboundChannelMessage] = []
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { message in
            receivedMessages.append(message)
        })

        try await client.emitInboundEvent(FeishuAdapterFixtures.singleChatTextEvent())

        #expect(receivedMessages.count == 1)
        #expect(receivedMessages.first?.text == "你好")
    }

    @Test func adapterForwardsGroupMentionMessageToHandler() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        var receivedMessages: [InboundChannelMessage] = []
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { message in
            receivedMessages.append(message)
        })

        try await client.emitInboundEvent(try FeishuAdapterFixtures.groupMentionTextEvent())

        #expect(receivedMessages.count == 1)
        #expect(receivedMessages.first?.externalConversationID == "oc_group_chat")
        #expect(receivedMessages.first?.mentionsBot == true)
    }

    @Test func adapterIgnoresGroupMessageWithoutMention() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        var receivedMessages: [InboundChannelMessage] = []
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { message in
            receivedMessages.append(message)
        })

        try await client.emitInboundEvent(try FeishuAdapterFixtures.groupPlainTextEvent())

        #expect(receivedMessages.isEmpty)
    }

    @Test func adapterSendsTextViaClient() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { _ in })

        let result = try await adapter.send(
            OutboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "oc_test_chat",
                text: "已处理",
                replyToExternalMessageID: "om_source"
            )
        )

        #expect(result == "om_sent")
        #expect(client.sentPayloads == [
            TestFeishuClient.SentPayload(
                chatID: "oc_test_chat",
                payload: FeishuRenderedMessagePayload(msgType: "text", content: #"{"text":"已处理"}"#),
                replyToMessageID: "om_source"
            )
        ])
    }

    @Test func adapterSendsPostPayloadWhenConfigured() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        FeishuChannelSettings(messageFormat: .post).apply(to: binding)
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { _ in })

        _ = try await adapter.send(
            OutboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "oc_test_chat",
                text: "已处理"
            )
        )

        let payload = try #require(client.sentPayloads.last?.payload)
        #expect(payload.msgType == "post")
        #expect(payload.content.contains("zh_cn"))
        #expect(payload.content.contains("已处理"))
    }

    @Test func adapterSendsInteractivePayloadWhenConfigured() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let binding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            displayName: "我的飞书 Bot"
        )
        FeishuChannelSettings(messageFormat: .interactive).apply(to: binding)
        try await adapter.start(configuration: IMChannelConfiguration(accountBinding: binding) { _ in })

        _ = try await adapter.send(
            OutboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "oc_test_chat",
                text: "已处理"
            )
        )

        let payload = try #require(client.sentPayloads.last?.payload)
        #expect(payload.msgType == "interactive")
        #expect(payload.content.contains("我的飞书 Bot"))
        #expect(payload.content.contains("已处理"))
    }

    @Test func registryRegistersStartsAndStopsAdapter() async throws {
        let client = TestFeishuClient()
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        try credentialStore.save(appID: "cli_test", appSecret: "secret_test")
        let adapter = FeishuChannelAdapter(client: client, credentialStore: credentialStore)
        let registry = IMChannelRegistry()
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")
        registry.register(adapter)

        try await registry.start(kind: .feishu, configuration: IMChannelConfiguration(accountBinding: binding) { _ in })
        await registry.stop(kind: .feishu)

        #expect(client.startCallCount == 1)
        #expect(client.stopCallCount == 1)
        #expect(registry.adapter(for: .feishu) != nil)
    }
}

private enum FeishuAdapterFixtures {
    static func singleChatTextEvent() -> FeishuEventEnvelope {
        FeishuEventEnvelope(
            header: .init(eventType: "im.message.receive_v1"),
            event: .init(
                sender: .init(senderID: .init(openID: "ou_test_user")),
                message: .init(
                    messageID: "om_test_message",
                    chatID: "oc_test_chat",
                    messageType: "text",
                    chatType: "p2p",
                    content: "{\"text\":\"你好\"}"
                )
            )
        )
    }

        static func groupMentionTextEvent() throws -> FeishuEventEnvelope {
            try decodeEvent(
                #"""
                {
                    "header": { "event_type": "im.message.receive_v1" },
                    "event": {
                        "sender": { "sender_id": { "open_id": "ou_group_user" } },
                        "message": {
                            "message_id": "om_group_message",
                            "chat_id": "oc_group_chat",
                            "chat_type": "group",
                            "message_type": "text",
                            "content": "{\"text\":\"@bot 帮我总结一下\"}",
                            "mentions": [
                                {
                                    "key": "@_user_1",
                                    "name": "agentGui Bot",
                                    "tenant_key": "tenant-1",
                                    "id": { "open_id": "ou_bot_open_id" }
                                }
                            ]
                        }
                    }
                }
                """#
            )
        }

        static func groupPlainTextEvent() throws -> FeishuEventEnvelope {
                try decodeEvent(
                #"""
                        {
                            "header": { "event_type": "im.message.receive_v1" },
                            "event": {
                                "sender": { "sender_id": { "open_id": "ou_group_user" } },
                                "message": {
                                    "message_id": "om_group_plain_message",
                                    "chat_id": "oc_group_chat",
                                    "chat_type": "group",
                                    "message_type": "text",
                                    "content": "{\"text\":\"大家好\"}",
                                    "mentions": []
                                }
                            }
                        }
                """#
                )
        }

        static func decodeEvent(_ json: String) throws -> FeishuEventEnvelope {
                try JSONDecoder().decode(FeishuEventEnvelope.self, from: Data(json.utf8))
        }
}

@MainActor
private final class TestFeishuClient: FeishuClient {
    struct SentPayload: Equatable {
        let chatID: String
        let payload: FeishuRenderedMessagePayload
        let replyToMessageID: String?
    }

    private var inboundHandler: ((FeishuEventEnvelope) async throws -> Void)?
    private(set) var startedCredentials: FeishuCredentials?
    private(set) var sentPayloads: [SentPayload] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(credentials: FeishuCredentials, onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void) async throws {
        startedCredentials = credentials
        inboundHandler = onEvent
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
        inboundHandler = nil
    }

    func sendMessage(
        chatID: String,
        payload: FeishuRenderedMessagePayload,
        replyToMessageID: String?
    ) async throws -> String {
        sentPayloads.append(SentPayload(chatID: chatID, payload: payload, replyToMessageID: replyToMessageID))
        return "om_sent"
    }

    func sendText(chatID: String, text: String, replyToMessageID: String?) async throws -> String {
        try await sendMessage(
            chatID: chatID,
            payload: FeishuRenderedMessagePayload(msgType: "text", content: #"{"text":"\#(text)"}"#),
            replyToMessageID: replyToMessageID
        )
    }

    func emitInboundEvent(_ event: FeishuEventEnvelope) async throws {
        try await inboundHandler?(event)
    }
}