import Foundation

enum MemoryKind: String, Codable, Sendable {
    case working
    case episodic
    case semantic
    case procedural
    case archive
}