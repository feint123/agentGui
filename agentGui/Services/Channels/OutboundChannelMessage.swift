import Foundation

struct OutboundChannelMessage: Equatable, Sendable {
    let channelKind: IMChannelKind
    let externalConversationID: String
    let text: String
    let replyToExternalMessageID: String?

    init(
        channelKind: IMChannelKind,
        externalConversationID: String,
        text: String,
        replyToExternalMessageID: String? = nil
    ) {
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.text = text
        self.replyToExternalMessageID = replyToExternalMessageID
    }
}