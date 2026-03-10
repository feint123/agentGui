import Foundation

enum MemoryLayer: String, CaseIterable, Codable, Sendable {
    case instant
    case working
    case task
    case episodic
    case semantic
    case proceduralArchive
}