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
        guard envelope.event.message.isDirectChat || envelope.event.message.isGroupChat else {
            throw NormalizationError.unsupportedChatType
        }

        guard let textContent = try? envelope.event.message.decodeContent(FeishuTextContent.self),
              !textContent.text.isEmpty else {
            throw NormalizationError.invalidContent
        }

        guard !envelope.event.message.chatID.isEmpty,
              !envelope.event.message.messageID.isEmpty,
              !(envelope.event.sender.senderID.openID ?? "").isEmpty else {
            throw NormalizationError.missingRequiredField
        }

        return InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: envelope.event.message.chatID,
            externalMessageID: envelope.event.message.messageID,
            externalUserID: envelope.event.sender.senderID.openID ?? "",
            text: textContent.text,
            mentionsBot: envelope.event.message.mentionsBot,
            rawPayload: envelope.event.message.content,
            receivedAt: Date()
        )
    }

    func shouldDispatch(_ envelope: FeishuEventEnvelope) -> Bool {
        if envelope.event.message.isDirectChat {
            return true
        }
        if envelope.event.message.isGroupChat {
            return envelope.event.message.mentionsBot
        }
        return false
    }
}