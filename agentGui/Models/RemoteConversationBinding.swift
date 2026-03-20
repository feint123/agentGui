import Foundation
import SwiftData

@Model
final class RemoteConversationBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var externalConversationID: String
    var externalUserID: String
    var providerIDRaw: String=""
    var remoteSessionID: String=""
    var cliVersion: String=""
    var lastSelectedModel: String=""
    var lastSelectedAgentName: String=""
    var lastHandshakeAt: Date?
    var session: Session?
    var sessionID: String=""
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        externalConversationID: String,
        externalUserID: String,
        providerIDRaw: String = "",
        remoteSessionID: String = "",
        cliVersion: String = "",
        lastSelectedModel: String = "",
        lastSelectedAgentName: String = "",
        lastHandshakeAt: Date? = nil,
        session: Session? = nil,
        sessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.externalUserID = externalUserID
        self.providerIDRaw = providerIDRaw
        self.remoteSessionID = remoteSessionID
        self.cliVersion = cliVersion
        self.lastSelectedModel = lastSelectedModel
        self.lastSelectedAgentName = lastSelectedAgentName
        self.lastHandshakeAt = lastHandshakeAt
        self.session = session
        self.sessionID = session?.sessionId ?? sessionID ?? ""
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension RemoteConversationBinding {
    var providerID: ConversationExecutionProviderID? {
        ConversationExecutionProviderID(rawValue: providerIDRaw)
    }

    func attach(to session: Session) {
        self.session = session
        self.sessionID = session.sessionId
    }
}