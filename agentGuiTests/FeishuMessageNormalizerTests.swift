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
}