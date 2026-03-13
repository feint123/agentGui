import Foundation

struct MemoryEvidenceAnchor: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Equatable, Sendable {
        case toolCall
        case message
        case file
        case verificationArtifact
    }

    var id: String {
        "\(kind.rawValue):\(identifier)"
    }

    var kind: Kind
    var identifier: String
    var summary: String
}