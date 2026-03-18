import Foundation

enum IMChannelKind: String, Codable, CaseIterable, Sendable {
    case feishu

    var displayName: String {
        switch self {
        case .feishu:
            return "Feishu"
        }
    }
}