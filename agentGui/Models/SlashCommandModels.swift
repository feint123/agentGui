import Foundation

enum ChatSlashCommandKind: String, Hashable, Codable {
    case skill
    case agent
    case preset
    case contextAction
}

enum ChatSlashCommandPayload: Hashable, Codable {
    case skill(directoryName: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case directoryName
    }

    private enum PayloadType: String, Codable {
        case skill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .skill:
            self = .skill(directoryName: try container.decode(String.self, forKey: .directoryName))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skill(let directoryName):
            try container.encode(PayloadType.skill, forKey: .type)
            try container.encode(directoryName, forKey: .directoryName)
        }
    }
}

struct ChatSlashCommandItem: Identifiable, Hashable {
    let id: String
    let kind: ChatSlashCommandKind
    let title: String
    let subtitle: String
    let aliases: [String]
    let badge: String?
    let isEnabledByDefault: Bool
    let payload: ChatSlashCommandPayload
}