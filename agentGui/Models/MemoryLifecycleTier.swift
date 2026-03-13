import Foundation

enum MemoryLifecycleTier: String, Codable, Equatable, Sendable {
    case hot
    case warm
    case cold
    case archive
}