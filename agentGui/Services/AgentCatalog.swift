import Foundation

protocol AgentCatalogProtocol: Sendable {
    var all: [AgentRuntimeDefinition] { get }
    var subagentInvocableAgents: [AgentRuntimeDefinition] { get }
    var userInvocableAgents: [AgentRuntimeDefinition] { get }
    var agentListText: String { get }
    var agentNameListText: String { get }
    var workflowRoleDefinitions: [WorkflowRoleDefinition] { get }

    func find(named name: String) -> AgentRuntimeDefinition?
}

struct AgentCatalog: AgentCatalogProtocol, Sendable {
    let all: [AgentRuntimeDefinition]

    init(loader: AgentDefinitionLoader = AgentDefinitionLoader(), bundle: Bundle = .main) throws {
        self.all = try loader.loadBuiltInRuntimeDefinitions(from: bundle)
    }

    var subagentInvocableAgents: [AgentRuntimeDefinition] {
        all.filter(\.subagentInvocable)
    }

    var userInvocableAgents: [AgentRuntimeDefinition] {
        all.filter(\.userInvocable)
    }

    var agentListText: String {
        subagentInvocableAgents
            .map { "- \($0.name) (\($0.displayName)): \($0.description)" }
            .joined(separator: "\n")
    }

    var agentNameListText: String {
        subagentInvocableAgents.map(\.name).joined(separator: " | ")
    }

    var workflowRoleDefinitions: [WorkflowRoleDefinition] {
        all.map(\.workflowRoleDefinition)
    }

    func find(named name: String) -> AgentRuntimeDefinition? {
        all.first(where: { $0.name == name })
    }
}

extension AgentCatalog {
    static let shared: AgentCatalog = {
        do {
            return try AgentCatalog()
        } catch {
            fatalError("Failed to load built-in agents: \(error.localizedDescription)")
        }
    }()
}