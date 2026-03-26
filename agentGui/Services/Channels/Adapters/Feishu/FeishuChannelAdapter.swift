import Foundation

@MainActor
final class FeishuChannelAdapter: IMChannelAdapter, ChannelProjectionDriver {
    enum AdapterError: Error {
        case missingCredentials
    }

    let kind: IMChannelKind = .feishu

    private let client: any FeishuClient
    private let normalizer: FeishuMessageNormalizer
    private let credentialStore: FeishuCredentialStore
    private let renderer: FeishuOutboundMessageRenderer
    private var configuration: IMChannelConfiguration?

    @MainActor
    init(
        client: (any FeishuClient)? = nil,
        normalizer: FeishuMessageNormalizer = FeishuMessageNormalizer(),
        credentialStore: FeishuCredentialStore = FeishuCredentialStore(),
        renderer: FeishuOutboundMessageRenderer = FeishuOutboundMessageRenderer()
    ) {
        self.client = client ?? LiveFeishuClient()
        self.normalizer = normalizer
        self.credentialStore = credentialStore
        self.renderer = renderer
    }

    func start(configuration: IMChannelConfiguration) async throws {
        guard let credentials = try credentialStore.load() else {
            throw AdapterError.missingCredentials
        }

        self.configuration = configuration
        try await client.start(credentials: credentials) { [normalizer] event in
            let message = try normalizer.normalize(event)
            guard normalizer.shouldDispatch(event) else {
                return
            }
            try await configuration.inboundMessageHandler(message)
        }
    }

    func stop() async {
        configuration = nil
        await client.stop()
    }

    func send(_ message: OutboundChannelMessage) async throws -> String {
        let format = configuration.map { FeishuChannelSettings(binding: $0.accountBinding).messageFormat } ?? .text
        let title = configuration?.accountBinding.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try renderer.render(
            text: message.text,
            format: format,
            title: title?.isEmpty == true ? nil : title
        )

        return try await client.sendMessage(
            chatID: message.externalConversationID,
            payload: payload,
            replyToMessageID: message.replyToExternalMessageID
        )
    }

    func openSession(context: ChannelProjectionContext) async throws -> (any ChannelProjectionSession)? {
        guard let configuration else { return nil }

        let format = FeishuChannelSettings(binding: configuration.accountBinding).messageFormat
        let title = configuration.accountBinding.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeishuProjectionSession(
            client: client,
            renderer: renderer,
            format: format,
            chatID: context.externalConversationID,
            replyToMessageID: context.replyToExternalMessageID,
            title: title.isEmpty ? nil : title,
            sessionID: context.sessionID,
            modelContext: context.modelContext
        )
    }
}