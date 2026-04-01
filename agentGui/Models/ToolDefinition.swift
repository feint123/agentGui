import Foundation
import SwiftAnthropic

enum ToolCategory: String, Codable {
    case editor
    case shell
    case web
    case memory
    case system
}

enum ToolContext: String, Codable, Hashable {
    case mainAgent
    case subagent
    case backgroundTask
}

struct ToolDefinitionBuildContext {
    let agentCatalog: any AgentCatalogProtocol

    static let `default` = ToolDefinitionBuildContext(
        agentCatalog: AgentCatalog.shared
    )

    var agentListText: String {
        agentCatalog.agentListText
    }

    var agentNameListText: String {
        agentCatalog.agentNameListText
    }
}

struct ToolDefinition {
    let id: String
    let displayName: String
    let category: ToolCategory
    let schemaVersion: Int
    let supportedContexts: Set<ToolContext>
    let authorization: ToolAuthorizationDescriptor
    /// Whether this tool is safe to execute concurrently with other tools
    /// that share this flag. Read-only tools (LSP queries, payload reads,
    /// web fetches) should return true. Write/execute tools must return false.
    let isConcurrencySafe: Bool
    let executorKey: String
    let descriptionBuilder: (ToolDefinitionBuildContext) -> String
    let inputSchemaBuilder: (ToolDefinitionBuildContext) -> JSONSchema

    init(
        id: String,
        displayName: String,
        category: ToolCategory,
        schemaVersion: Int,
        supportedContexts: Set<ToolContext>,
        authorization: ToolAuthorizationDescriptor = .none,
        isConcurrencySafe: Bool = false,
        executorKey: String,
        descriptionBuilder: @escaping (ToolDefinitionBuildContext) -> String,
        inputSchemaBuilder: @escaping (ToolDefinitionBuildContext) -> JSONSchema
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.schemaVersion = schemaVersion
        self.supportedContexts = supportedContexts
        self.authorization = authorization
        self.isConcurrencySafe = isConcurrencySafe
        self.executorKey = executorKey
        self.descriptionBuilder = descriptionBuilder
        self.inputSchemaBuilder = inputSchemaBuilder
    }

    func makeAnthropicTool(context: ToolDefinitionBuildContext = .default) -> MessageParameter.Tool {
        .function(
            name: id,
            description: descriptionBuilder(context),
            inputSchema: inputSchemaBuilder(context),
            cacheControl: .init(type: .ephemeral)
        )
    }
}