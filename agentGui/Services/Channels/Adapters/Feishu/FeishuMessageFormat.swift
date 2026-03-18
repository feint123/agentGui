import Foundation

enum FeishuMessageFormat: String, CaseIterable, Codable, Sendable {
    case text
    case post
    case interactive
}