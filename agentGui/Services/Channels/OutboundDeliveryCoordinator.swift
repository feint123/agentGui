import Foundation
import SwiftData

@MainActor
struct OutboundDeliveryCoordinator {
    enum DeliveryError: Error {
        case missingAdapter(IMChannelKind)
    }

    private let adapterProvider: @Sendable (IMChannelKind) -> (any IMChannelAdapter)?

    init(adapterProvider: @escaping @Sendable (IMChannelKind) -> (any IMChannelAdapter)?) {
        self.adapterProvider = adapterProvider
    }

    func deliver(
        _ message: OutboundChannelMessage,
        sourceMessage: Message?,
        modelContext: ModelContext
    ) async throws -> String {
        guard let adapter = adapterProvider(message.channelKind) else {
            throw DeliveryError.missingAdapter(message.channelKind)
        }

        let externalMessageID = try await adapter.send(message)
        let receipt = RemoteMessageReceipt(
            channelKind: message.channelKind,
            externalConversationID: message.externalConversationID,
            externalMessageID: externalMessageID,
            direction: .outbound,
            messageID: sourceMessage?.id
        )
        modelContext.insert(receipt)
        try modelContext.save()
        return externalMessageID
    }
}