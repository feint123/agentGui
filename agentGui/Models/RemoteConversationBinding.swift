import Foundation
import SwiftData

@Model
final class RemoteConversationBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var externalConversationID: String
    var externalUserID: String
    var sessionID: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        externalConversationID: String,
        externalUserID: String,
        sessionID: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.externalUserID = externalUserID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}