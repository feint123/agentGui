import Foundation

enum ChatInputDirective: Identifiable, Hashable, Codable {
    case skill(SkillInputDirective)

    var id: String {
        switch self {
        case .skill(let value):
            return "skill:\(value.directoryName)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case skill
    }

    private enum DirectiveType: String, Codable {
        case skill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DirectiveType.self, forKey: .type) {
        case .skill:
            self = .skill(try container.decode(SkillInputDirective.self, forKey: .skill))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skill(let value):
            try container.encode(DirectiveType.skill, forKey: .type)
            try container.encode(value, forKey: .skill)
        }
    }
}

struct SkillInputDirective: Hashable, Codable {
    let directoryName: String
    let displayName: String
}

extension ChatInputDirective {
    var auditDescription: String {
        switch self {
        case .skill(let value):
            return "skill=\(value.directoryName)"
        }
    }
}

enum ChatInputDirectiveAudit {
    static func appendAuditTrail(to text: String, directives: [ChatInputDirective]) -> String {
        guard !directives.isEmpty else { return text }
        let audit = directives.map(\.auditDescription).joined(separator: ", ")
        return text + "\n\n[Active directives] \(audit)"
    }
}