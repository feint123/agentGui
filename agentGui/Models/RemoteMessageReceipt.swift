import Foundation
import SwiftData

enum RemoteMessageDirection: String, Codable, Sendable {
    case inbound
    case outbound
}

@Model
final class RemoteMessageReceipt {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var externalConversationID: String
    var externalMessageID: String
    var direction: RemoteMessageDirection
    var messageID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        externalConversationID: String,
        externalMessageID: String,
        direction: RemoteMessageDirection,
        messageID: UUID?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.externalMessageID = externalMessageID
        self.direction = direction
        self.messageID = messageID
        self.createdAt = createdAt
    }
}