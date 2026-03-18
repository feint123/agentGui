import Foundation
import SwiftData

@MainActor
struct ChannelEventDeduplicator {
    func acceptInbound(_ message: InboundChannelMessage, modelContext: ModelContext) throws -> Bool {
        let existingReceipts = try modelContext.fetch(FetchDescriptor<RemoteMessageReceipt>())
        if existingReceipts.contains(where: {
            $0.channelKind == message.channelKind &&
            $0.externalMessageID == message.externalMessageID &&
            $0.direction == .inbound
        }) {
            return false
        }

        let receipt = RemoteMessageReceipt(
            channelKind: message.channelKind,
            externalConversationID: message.externalConversationID,
            externalMessageID: message.externalMessageID,
            direction: .inbound,
            messageID: nil,
            createdAt: message.receivedAt
        )
        modelContext.insert(receipt)
        try modelContext.save()
        return true
    }
}