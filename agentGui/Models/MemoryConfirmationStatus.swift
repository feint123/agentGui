import Foundation

enum MemoryConfirmationStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case failedToApply
}