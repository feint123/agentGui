import Foundation

enum AgentTeamRunStatus: String, Codable, CaseIterable, Sendable {
    case created
    case active
    case completed
    case failed
}