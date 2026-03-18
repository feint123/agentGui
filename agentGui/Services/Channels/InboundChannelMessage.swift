import Foundation

struct InboundChannelMessage: Equatable, Sendable {
    let channelKind: IMChannelKind
    let externalConversationID: String
    let externalMessageID: String
    let externalUserID: String
    let text: String
    let mentionsBot: Bool
    let rawPayload: String
    let receivedAt: Date
}