import Foundation

enum LegacyExternalACPProviderKey: String, Codable, CaseIterable, Sendable {
    case githubCopilotCLI = "github_copilot_cli"
    case openCodeCLI = "opencode_cli"
    case claudeAdapterCLI = "claude_adapter_cli"
}

extension LegacyExternalACPProviderKey {
    var presetProfileID: UUID {
        switch self {
        case .githubCopilotCLI:
            return UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        case .openCodeCLI:
            return UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        case .claudeAdapterCLI:
            return UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        }
    }

    var conversationExecutionProviderID: ConversationExecutionProviderID {
        switch self {
        case .githubCopilotCLI:
            return .githubCopilotCLI
        case .openCodeCLI:
            return .openCodeCLI
        case .claudeAdapterCLI:
            return .claudeAdapterCLI
        }
    }

    var compatibilityReference: ExecutionProviderReference {
        .externalACP(profileID: presetProfileID)
    }
}

enum ExecutionProviderReference: Hashable, Sendable {
    case builtIn
    case externalACP(profileID: UUID)

    private static let externalACPPrefix = "external_acp:"

    var persistedValue: String {
        switch self {
        case .builtIn:
            return ConversationExecutionProviderID.builtInAgent.rawValue
        case let .externalACP(profileID):
            return Self.externalACPPrefix + profileID.uuidString.lowercased()
        }
    }

    static func compatibilityReference(for providerID: ConversationExecutionProviderID?) -> ExecutionProviderReference? {
        guard let providerID else {
            return nil
        }

        if providerID == .builtInAgent {
            return .builtIn
        }

        return LegacyExternalACPProviderKey.allCases.first(where: {
            $0.conversationExecutionProviderID == providerID
        })?.compatibilityReference ?? .builtIn
    }

    static func decodePersisted(_ rawValue: String?) -> ExecutionProviderReference {
        guard let rawValue, rawValue.isEmpty == false else {
            return .builtIn
        }

        if rawValue == ConversationExecutionProviderID.builtInAgent.rawValue {
            return .builtIn
        }

        if let profileID = profileID(from: rawValue) {
            return .externalACP(profileID: profileID)
        }

        return .builtIn
    }

    static func legacyExternalACPKey(from rawValue: String?) -> LegacyExternalACPProviderKey? {
        guard let rawValue else {
            return nil
        }

        return LegacyExternalACPProviderKey(rawValue: rawValue)
    }

    private static func profileID(from rawValue: String) -> UUID? {
        guard rawValue.hasPrefix(externalACPPrefix) else {
            return nil
        }

        let value = String(rawValue.dropFirst(externalACPPrefix.count))
        return UUID(uuidString: value)
    }

    var compatibilityProviderID: ConversationExecutionProviderID? {
        switch self {
        case .builtIn:
            return .builtInAgent
        case let .externalACP(profileID):
            return LegacyExternalACPProviderKey.allCases.first {
                $0.compatibilityReference == .externalACP(profileID: profileID)
            }?.conversationExecutionProviderID
        }
    }

    var profileID: UUID? {
        switch self {
        case .builtIn:
            return nil
        case let .externalACP(profileID):
            return profileID
        }
    }
}

extension ExecutionProviderReference: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.decodePersisted(rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistedValue)
    }
}