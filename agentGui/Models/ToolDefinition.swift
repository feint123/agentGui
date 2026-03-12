import Foundation
import SwiftAnthropic

enum ToolCategory: String, Codable {
    case editor
    case shell
    case web
    case workflow
    case memory
    case system
}

enum ToolContext: String, Codable, Hashable {
    case mainAgent
    case subagent
    case workflowWorker
}

struct ToolDefinitionBuildContext {
    let agentCatalog: any AgentCatalogProtocol
    let availableWorkflows: [(id: String, displayName: String, description: String)]

    static let `default` = ToolDefinitionBuildContext(
        agentCatalog: AgentCatalog.shared,
        availableWorkflows: ClaudeService.availableWorkflows
    )

    var agentListText: String {
        agentCatalog.agentListText
    }

    var agentNameListText: String {
        agentCatalog.agentNameListText
    }

    var workflowListText: String {
        availableWorkflows
            .map { "- \($0.id): \($0.description)" }
            .joined(separator: "\n")
    }

    var workflowIDListText: String {
        availableWorkflows.map(\.id).joined(separator: " | ")
    }
}

struct ToolDefinition {
    let id: String
    let displayName: String
    let category: ToolCategory
    let schemaVersion: Int
    let supportedContexts: Set<ToolContext>
    let executorKey: String
    let descriptionBuilder: (ToolDefinitionBuildContext) -> String
    let inputSchemaBuilder: (ToolDefinitionBuildContext) -> JSONSchema

    func makeAnthropicTool(context: ToolDefinitionBuildContext = .default) -> MessageParameter.Tool {
        .function(
            name: id,
            description: descriptionBuilder(context),
            inputSchema: inputSchemaBuilder(context),
            cacheControl: .init(type: .ephemeral)
        )
    }
}