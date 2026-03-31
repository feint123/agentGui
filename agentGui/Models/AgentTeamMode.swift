import Foundation

enum AgentTeamMode: String, Codable, CaseIterable, Sendable {
    case executionDelivery
    case creativeExploration
}

extension AgentTeamMode {
    var displayName: String {
        switch self {
        case .executionDelivery:   return "执行交付"
        case .creativeExploration: return "创意探索"
        }
    }
}