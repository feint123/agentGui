import Foundation

enum ExecutionPayloadDraft: Codable, Equatable, Sendable {
    case userPrompt(
        text: String,
        modelID: String,
        selectedFilePath: String?,
        selectedText: String?,
        directives: [ChatInputDirective],
        teamContext: AgentTeamExecutionContext?
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case modelID
        case selectedFilePath
        case selectedText
        case directives
        case teamContext
    }

    private enum Kind: String, Codable {
        case userPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .userPrompt:
            self = .userPrompt(
                text: try container.decode(String.self, forKey: .text),
                modelID: try container.decode(String.self, forKey: .modelID),
                selectedFilePath: try container.decodeIfPresent(String.self, forKey: .selectedFilePath),
                selectedText: try container.decodeIfPresent(String.self, forKey: .selectedText),
                directives: try container.decodeIfPresent([ChatInputDirective].self, forKey: .directives) ?? [],
                teamContext: try container.decodeIfPresent(AgentTeamExecutionContext.self, forKey: .teamContext)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .userPrompt(text, modelID, selectedFilePath, selectedText, directives, teamContext):
            try container.encode(Kind.userPrompt, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(modelID, forKey: .modelID)
            try container.encodeIfPresent(selectedFilePath, forKey: .selectedFilePath)
            try container.encodeIfPresent(selectedText, forKey: .selectedText)
            try container.encode(directives, forKey: .directives)
            try container.encodeIfPresent(teamContext, forKey: .teamContext)
        }
    }
}

extension ExecutionPayloadDraft {
    var teamContext: AgentTeamExecutionContext? {
        switch self {
        case let .userPrompt(_, _, _, _, _, teamContext):
            return teamContext
        }
    }

    var encodedJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = payload
    }
}