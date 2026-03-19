import Foundation
import SwiftData

struct ChannelProjectionContext: Equatable {
    let channelKind: IMChannelKind
    let externalConversationID: String
    let replyToExternalMessageID: String?
    let formatHint: String?
    let sessionID: String?
    let modelContext: ModelContext?

    init(
        channelKind: IMChannelKind,
        externalConversationID: String,
        replyToExternalMessageID: String? = nil,
        formatHint: String? = nil,
        sessionID: String? = nil,
        modelContext: ModelContext? = nil
    ) {
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.replyToExternalMessageID = replyToExternalMessageID
        self.formatHint = formatHint
        self.sessionID = sessionID
        self.modelContext = modelContext
    }

    static func == (lhs: ChannelProjectionContext, rhs: ChannelProjectionContext) -> Bool {
        lhs.channelKind == rhs.channelKind &&
        lhs.externalConversationID == rhs.externalConversationID &&
        lhs.replyToExternalMessageID == rhs.replyToExternalMessageID &&
        lhs.formatHint == rhs.formatHint &&
        lhs.sessionID == rhs.sessionID
    }
}

@MainActor
protocol ChannelProjectionDriver {
    func openSession(context: ChannelProjectionContext) async throws -> (any ChannelProjectionSession)?
}
