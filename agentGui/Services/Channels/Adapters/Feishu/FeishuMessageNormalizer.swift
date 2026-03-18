import Foundation

struct FeishuMessageNormalizer {
    enum NormalizationError: Error {
        case unsupportedEventType
        case unsupportedMessageType
        case unsupportedChatType
        case invalidContent
        case missingRequiredField
    }

    func normalize(_ envelope: FeishuEventEnvelope) throws -> InboundChannelMessage {
        guard envelope.header.eventType == "im.message.receive_v1" else {
            throw NormalizationError.unsupportedEventType
        }
        guard envelope.event.message.messageType == "text" else {
            throw NormalizationError.unsupportedMessageType
        }
        guard envelope.event.message.chatType == "p2p" else {
            throw NormalizationError.unsupportedChatType
        }

        let payloadData = Data(envelope.event.message.content.utf8)
        guard let textContent = try? JSONDecoder().decode(FeishuTextContent.self, from: payloadData),
              !textContent.text.isEmpty else {
            throw NormalizationError.invalidContent
        }

        guard !envelope.event.message.chatID.isEmpty,
              !envelope.event.message.messageID.isEmpty,
              !envelope.event.sender.senderID.openID.isEmpty else {
            throw NormalizationError.missingRequiredField
        }

        return InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: envelope.event.message.chatID,
            externalMessageID: envelope.event.message.messageID,
            externalUserID: envelope.event.sender.senderID.openID,
            text: textContent.text,
            mentionsBot: false,
            rawPayload: envelope.event.message.content,
            receivedAt: Date()
        )
    }
}