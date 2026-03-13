import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct ToolRegistryTests {

    @Test func registryContainsCoreBuiltInTools() throws {
        let registry = DefaultToolRegistry()

        #expect(registry.definition(for: "bash") != nil)
        #expect(registry.definition(for: "str_replace_based_edit_tool") != nil)
        #expect(registry.definition(for: "web_search") != nil)
        #expect(registry.definition(for: "web_fetch") != nil)
        #expect(registry.definition(for: "lsp_definition") != nil)
        #expect(registry.definition(for: "lsp_references") != nil)
        #expect(registry.definition(for: "lsp_hover") != nil)
        #expect(registry.definition(for: "lsp_document_symbols") != nil)
        #expect(registry.definition(for: "lsp_workspace_symbols") != nil)
        #expect(registry.definition(for: "lsp_diagnostics") != nil)
        #expect(registry.definition(for: "lsp_list_servers") != nil)
        #expect(registry.definition(for: "lsp_server_status") != nil)
        #expect(registry.definition(for: "run_subagent") != nil)
        #expect(registry.definition(for: "start_workflow") != nil)
    }

    @Test func toolDefinitionBuildsAnthropicToolFromSingleSchemaSource() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "bash"))
        let tool = definition.makeAnthropicTool()

        let payload = try #require(encodedToolDictionary(from: tool))
        let schema = try #require(payload["input_schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(properties.keys.contains("execution_mode"))
        #expect(properties.keys.contains("task_id"))
        #expect((payload["cache_control"] as? [String: String])?["type"] == "ephemeral")
    }

    @Test func runSubagentToolExposesOnlyThreeBuiltInAgents() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "run_subagent"))
        let tool = definition.makeAnthropicTool()

        let payload = try #require(encodedToolDictionary(from: tool))
        let description = try #require(payload["description"] as? String)
        let schema = try #require(payload["input_schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let agentName = try #require(properties["agent_name"] as? [String: Any])
        let agentDescription = try #require(agentName["description"] as? String)

        #expect(description.contains("explore"))
        #expect(description.contains("worker"))
        #expect(description.contains("verifier"))
        #expect(!description.contains("planner"))
        #expect(!description.contains("coder"))
        #expect(!description.contains("reviewer"))
        #expect(!description.contains("executor"))

        #expect(agentDescription.contains("explore | worker | verifier"))
    }

    private func encodedToolDictionary(from tool: MessageParameter.Tool) -> [String: Any]? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(tool),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }
}