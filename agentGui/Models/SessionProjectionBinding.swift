import Foundation
import SwiftData

enum SessionProjectionBindingState: String, Codable, Sendable {
    case active
    case completed
    case failed
}

@Model
final class SessionProjectionBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var session: Session?
    var sessionID: String
    var channelKind: IMChannelKind
    var externalConversationID: String
    var formatHint: String?
    var primaryExternalMessageID: String?
    var latestExternalMessageID: String?
    var stateRaw: String
    var lastErrorSummary: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        session: Session? = nil,
        sessionID: String? = nil,
        channelKind: IMChannelKind,
        externalConversationID: String,
        formatHint: String? = nil,
        primaryExternalMessageID: String? = nil,
        latestExternalMessageID: String? = nil,
        state: SessionProjectionBindingState = .active,
        lastErrorSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.sessionID = session?.sessionId ?? sessionID ?? ""
        self.channelKind = channelKind
        self.externalConversationID = externalConversationID
        self.formatHint = formatHint
        self.primaryExternalMessageID = primaryExternalMessageID
        self.latestExternalMessageID = latestExternalMessageID
        self.stateRaw = state.rawValue
        self.lastErrorSummary = lastErrorSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SessionProjectionBinding {
    var state: SessionProjectionBindingState {
        get { SessionProjectionBindingState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }
}