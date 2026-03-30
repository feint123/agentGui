import Foundation
import SwiftData

@Model
final class AgentTeamSessionState {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var session: Session?
    var sourceSessionID: String
    var sourceSessionTitle: String
    var modeRaw: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        session: Session,
        sourceSessionID: String = "",
        sourceSessionTitle: String = "",
        mode: AgentTeamMode = .executionDelivery,
        status: AgentTeamRunStatus = .created,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.session = session
        self.sourceSessionID = sourceSessionID
        self.sourceSessionTitle = sourceSessionTitle
        self.modeRaw = mode.rawValue
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension AgentTeamSessionState {
    var mode: AgentTeamMode {
        get { AgentTeamMode(rawValue: modeRaw) ?? .executionDelivery }
        set {
            modeRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var status: AgentTeamRunStatus {
        get { AgentTeamRunStatus(rawValue: statusRaw) ?? .created }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
        }
    }
}