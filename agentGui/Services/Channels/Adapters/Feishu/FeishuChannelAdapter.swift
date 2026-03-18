import Foundation

@MainActor
final class FeishuChannelAdapter: IMChannelAdapter {
    enum AdapterError: Error {
        case missingCredentials
    }

    let kind: IMChannelKind = .feishu

    private let client: any FeishuClient
    private let normalizer: FeishuMessageNormalizer
    private let credentialStore: FeishuCredentialStore
    private var configuration: IMChannelConfiguration?

    init(
        client: (any FeishuClient)? = nil,
        normalizer: FeishuMessageNormalizer = FeishuMessageNormalizer(),
        credentialStore: FeishuCredentialStore = FeishuCredentialStore()
    ) {
        self.client = client ?? LiveFeishuClient()
        self.normalizer = normalizer
        self.credentialStore = credentialStore
    }

    func start(configuration: IMChannelConfiguration) async throws {
        guard let credentials = try credentialStore.load() else {
            throw AdapterError.missingCredentials
        }

        self.configuration = configuration
        try await client.start(credentials: credentials) { [normalizer] event in
            let message = try normalizer.normalize(event)
            try await configuration.inboundMessageHandler(message)
        }
    }

    func stop() async {
        configuration = nil
        await client.stop()
    }

    func send(_ message: OutboundChannelMessage) async throws -> String {
        try await client.sendText(
            chatID: message.externalConversationID,
            text: message.text,
            replyToMessageID: message.replyToExternalMessageID
        )
    }
}