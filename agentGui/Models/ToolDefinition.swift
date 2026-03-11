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
    let availableAgents: [WorkflowRoleDefinition]
    let availableWorkflows: [(id: String, displayName: String, description: String)]

    static let `default` = ToolDefinitionBuildContext(
        availableAgents: WorkflowRoleDefinition.all,
        availableWorkflows: ClaudeService.availableWorkflows
    )

    var agentListText: String {
        availableAgents
            .map { "- \($0.name) (\($0.displayName)): \($0.description)" }
            .joined(separator: "\n")
    }

    var agentNameListText: String {
        availableAgents.map(\.name).joined(separator: " | ")
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