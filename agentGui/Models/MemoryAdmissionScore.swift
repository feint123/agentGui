import Foundation

struct MemoryAdmissionScore: Codable, Equatable, Sendable {
    enum Route: String, Codable, Equatable, Sendable {
        case hotPath
        case background
        case confirmation
        case archiveOnly
        case reject
    }

    var total: Double
    var route: Route
}