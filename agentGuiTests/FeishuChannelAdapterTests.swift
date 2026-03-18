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
        #expect(client.sentPayloads == [TestFeishuClient.SentPayload(chatID: "oc_test_chat", text: "已处理", replyToMessageID: "om_source")])
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
}

@MainActor
private final class TestFeishuClient: FeishuClient {
    struct SentPayload: Equatable {
        let chatID: String
        let text: String
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

    func sendText(chatID: String, text: String, replyToMessageID: String?) async throws -> String {
        sentPayloads.append(SentPayload(chatID: chatID, text: text, replyToMessageID: replyToMessageID))
        return "om_sent"
    }

    func emitInboundEvent(_ event: FeishuEventEnvelope) async throws {
        try await inboundHandler?(event)
    }
}