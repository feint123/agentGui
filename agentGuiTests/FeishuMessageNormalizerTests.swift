import Foundation
import Testing
@testable import agentGui

@MainActor
struct FeishuMessageNormalizerTests {
    @Test func normalizerBuildsInboundMessageFromFeishuTextEvent() throws {
        let payload = FeishuEventFixtures.singleChatTextEvent()
        let message = try FeishuMessageNormalizer().normalize(payload)

        #expect(message.channelKind == .feishu)
        #expect(message.externalConversationID == "oc_test_chat")
        #expect(message.externalMessageID == "om_test_message")
        #expect(message.externalUserID == "ou_test_user")
        #expect(message.text == "你好")
    }

        @Test func normalizerBuildsInboundMessageFromGroupAtBotEvent() throws {
            let payload = try FeishuEventFixtures.decodeEvent(
                #"""
                {
                    "header": { "event_type": "im.message.receive_v1" },
                    "event": {
                        "sender": {
                            "sender_id": { "open_id": "ou_group_user" },
                            "sender_type": "user",
                            "tenant_key": "tenant-1"
                        },
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
                                    "id": {
                                        "open_id": "ou_bot_open_id",
                                        "user_id": "bot_user_id"
                                    }
                                }
                            ]
                        }
                    }
                }
                """#
            )

            let message = try FeishuMessageNormalizer().normalize(payload)

            #expect(message.externalConversationID == "oc_group_chat")
            #expect(message.externalMessageID == "om_group_message")
            #expect(message.externalUserID == "ou_group_user")
            #expect(message.text == "@bot 帮我总结一下")
            #expect(message.mentionsBot)
        }

    @Test func normalizerRejectsNonTextMessage() throws {
        let payload = FeishuEventFixtures.imageMessageEvent()

        #expect(throws: FeishuMessageNormalizer.NormalizationError.self) {
            try FeishuMessageNormalizer().normalize(payload)
        }
    }

    @Test func credentialStoreReadsAndWritesCredentialsWithoutTouchingAppSettings() throws {
        let backend = InMemoryFeishuCredentialBackend()
        let store = FeishuCredentialStore(backend: backend)
        let settings = AppSettings.testFixture(apiKey: "anthropic-key")

        try store.save(appID: "cli_test", appSecret: "secret_test")
        let credentials = try #require(try store.load())

        #expect(credentials.appID == "cli_test")
        #expect(credentials.appSecret == "secret_test")
        #expect(settings.apiKey == "anthropic-key")
    }
}

private enum FeishuEventFixtures {
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

    static func imageMessageEvent() -> FeishuEventEnvelope {
        FeishuEventEnvelope(
            header: .init(eventType: "im.message.receive_v1"),
            event: .init(
                sender: .init(senderID: .init(openID: "ou_test_user")),
                message: .init(
                    messageID: "om_test_message",
                    chatID: "oc_test_chat",
                    messageType: "image",
                    chatType: "p2p",
                    content: "{}"
                )
            )
        )
    }

    static func decodeEvent(_ json: String) throws -> FeishuEventEnvelope {
        try JSONDecoder().decode(FeishuEventEnvelope.self, from: Data(json.utf8))
    }
}