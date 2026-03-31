import Foundation
import SwiftData

@Model
final class AgentTeamSessionState {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var session: Session?
    var sourceSessionID: String
    var sourceSessionTitle: String
    var briefJSON: String=""
    var claimBoardJSON: String=""
    var modeRaw: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        session: Session,
        sourceSessionID: String = "",
        sourceSessionTitle: String = "",
        briefJSON: String = "",
        claimBoardJSON: String = "",
        mode: AgentTeamMode = .executionDelivery,
        status: AgentTeamRunStatus = .created,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.session = session
        self.sourceSessionID = sourceSessionID
        self.sourceSessionTitle = sourceSessionTitle
        self.briefJSON = briefJSON
        self.claimBoardJSON = claimBoardJSON
        self.modeRaw = mode.rawValue
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension AgentTeamSessionState {
    var missionBrief: AgentTeamMissionBrief? {
        get {
            guard let data = briefJSON.data(using: .utf8),
                  let brief = try? JSONDecoder().decode(AgentTeamMissionBrief.self, from: data) else {
                return nil
            }
            return brief
        }
        set {
            updateMissionBrief(newValue)
        }
    }

    var claimBoardState: AgentTeamClaimBoardState? {
        get {
            guard let data = claimBoardJSON.data(using: .utf8),
                  let board = try? JSONDecoder().decode(AgentTeamClaimBoardState.self, from: data) else {
                return nil
            }
            return board
        }
        set {
            updateClaimBoard(newValue)
        }
    }

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

    func updateMissionBrief(_ brief: AgentTeamMissionBrief?) {
        guard let brief else {
            briefJSON = ""
            updatedAt = Date()
            return
        }

        guard let data = try? JSONEncoder().encode(brief),
              let encoded = String(data: data, encoding: .utf8) else {
            briefJSON = ""
            updatedAt = Date()
            return
        }

        briefJSON = encoded
        modeRaw = brief.mode.rawValue
        updatedAt = Date()
    }

    func updateClaimBoard(_ board: AgentTeamClaimBoardState?) {
        guard let board else {
            claimBoardJSON = ""
            updatedAt = Date()
            return
        }

        guard let data = try? JSONEncoder().encode(board),
              let encoded = String(data: data, encoding: .utf8) else {
            claimBoardJSON = ""
            updatedAt = Date()
            return
        }

        claimBoardJSON = encoded
        updatedAt = Date()
    }
}