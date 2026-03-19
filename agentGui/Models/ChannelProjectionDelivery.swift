import Foundation
import SwiftData

enum ChannelProjectionDeliveryKind: String, Codable, Sendable {
    case primary
    case append
    case update
    case finalize
    case fail
}

@Model
final class ChannelProjectionDelivery {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var session: Session?
    var sessionID: String
    var channelKind: IMChannelKind
    var externalConversationID: String
    var externalMessageID: String?
    var deliveryKind: ChannelProjectionDeliveryKind
    var summary: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        session: Session? = nil,
        sessionID: String? = nil,
        channelKind: IMChannelKind,
        externalConversationID: String,
        externalMessageID: String?,
        deliveryKind: ChannelProjectionDeliveryKind,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.sessionID = session?.sessionId ?? sessionID ?? ""
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.externalMessageID = externalMessageID
        self.deliveryKind = deliveryKind
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}