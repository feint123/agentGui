import Foundation

enum ACPCommandSource: String, Hashable, Codable {
    case remoteAdvertised
    case documentedSeed
}

enum ChatSlashCommandKind: String, Hashable, Codable {
    case skill
    case agent
    case preset
    case contextAction
}

enum ChatSlashCommandPayload: Hashable, Codable {
    case skill(directoryName: String)
    case acpCommand(
        name: String,
        argumentHint: String?,
        providerReference: ExecutionProviderReference,
        providerDisplayName: String,
        source: ACPCommandSource
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case directoryName
        case name
        case argumentHint
        case providerReference
        case providerDisplayName
        case source
    }

    private enum PayloadType: String, Codable {
        case skill
        case acpCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .skill:
            self = .skill(directoryName: try container.decode(String.self, forKey: .directoryName))
        case .acpCommand:
            self = .acpCommand(
                name: try container.decode(String.self, forKey: .name),
                argumentHint: try container.decodeIfPresent(String.self, forKey: .argumentHint),
                providerReference: try container.decode(ExecutionProviderReference.self, forKey: .providerReference),
                providerDisplayName: try container.decode(String.self, forKey: .providerDisplayName),
                source: try container.decode(ACPCommandSource.self, forKey: .source)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skill(let directoryName):
            try container.encode(PayloadType.skill, forKey: .type)
            try container.encode(directoryName, forKey: .directoryName)
        case .acpCommand(let name, let argumentHint, let providerReference, let providerDisplayName, let source):
            try container.encode(PayloadType.acpCommand, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(argumentHint, forKey: .argumentHint)
            try container.encode(providerReference, forKey: .providerReference)
            try container.encode(providerDisplayName, forKey: .providerDisplayName)
            try container.encode(source, forKey: .source)
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