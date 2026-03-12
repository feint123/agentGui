import Foundation

enum AgentValidationError: Error, LocalizedError, Equatable {
    case malformedFrontmatter(String)
    case missingRequiredField(String)
    case unsupportedFields([String])
    case invalidAgentName(String)
    case duplicateAgentName(String)
    case invalidIntegerField(String)
    case invalidBooleanField(String)
    case invalidOutputContract(String)
    case invalidVisibilityCombination
    case unknownToolGroup(String)
    case emptyBody
    case missingBuiltInAgentDirectory
    case missingBuiltInAgentFiles

    var errorDescription: String? {
        switch self {
        case .malformedFrontmatter(let detail):
            return "Malformed agent frontmatter: \(detail)"
        case .missingRequiredField(let field):
            return "Missing required agent field: \(field)"
        case .unsupportedFields(let fields):
            return "Unsupported agent fields: \(fields.sorted().joined(separator: ", "))"
        case .invalidAgentName(let name):
            return "Invalid built-in agent name: \(name)"
        case .duplicateAgentName(let name):
            return "Duplicate built-in agent name: \(name)"
        case .invalidIntegerField(let field):
            return "Invalid integer field: \(field)"
        case .invalidBooleanField(let field):
            return "Invalid boolean field: \(field)"
        case .invalidOutputContract(let value):
            return "Invalid output contract: \(value)"
        case .invalidVisibilityCombination:
            return "At least one of user-invocable or subagent-invocable must be true"
        case .unknownToolGroup(let toolGroup):
            return "Unknown agent tool group: \(toolGroup)"
        case .emptyBody:
            return "Agent body must not be empty"
        case .missingBuiltInAgentDirectory:
            return "Built-in agent directory is missing"
        case .missingBuiltInAgentFiles:
            return "Built-in agent files are missing"
        }
    }
}