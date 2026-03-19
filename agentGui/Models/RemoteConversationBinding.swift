import Foundation
import SwiftData

@Model
final class RemoteConversationBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var externalConversationID: String
    var externalUserID: String
    var session: Session?
    var sessionID: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        externalConversationID: String,
        externalUserID: String,
        session: Session? = nil,
        sessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.externalUserID = externalUserID
        self.session = session
        self.sessionID = session?.sessionId ?? sessionID ?? ""
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension RemoteConversationBinding {
    func attach(to session: Session) {
        self.session = session
        self.sessionID = session.sessionId
    }
}