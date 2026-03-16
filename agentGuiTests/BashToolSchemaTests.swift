import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct BashToolSchemaTests {

    @Test func toolBuilderExposesManagedTaskFields() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let bash = try #require(toolNamed("bash", in: tools))
        let propertyNames = schemaPropertyNames(from: bash)

        #expect(propertyNames.contains("execution_mode"))
        #expect(propertyNames.contains("task_id"))
        #expect(propertyNames.contains("operation"))
        #expect(propertyNames.contains("force"))
        #expect(propertyNames.contains("tail_lines"))
    }

    @Test func toolBuilderDoesNotExposeLegacyCompatibilityFields() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let bash = try #require(toolNamed("bash", in: tools))
        let propertyNames = schemaPropertyNames(from: bash)

        #expect(!propertyNames.contains("background"))
        #expect(!propertyNames.contains("interactive"))
        #expect(!propertyNames.contains("interrupt"))
        #expect(!propertyNames.contains("signal"))
    }

    @Test func bashToolDescriptionExplainsTaskIDReuseRules() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let bash = try #require(toolNamed("bash", in: tools))
        let description = try #require(encodedToolDictionary(from: bash)?["description"] as? String)

        #expect(description.contains("unique task_id"))
        #expect(description.contains("status"))
        #expect(description.contains("read_output"))
        #expect(description.contains("cleanup"))
    }

    @Test func parseOperationStartRequestMapsToPtyRuntimeContract() async throws {
        let request = try ClaudeService().parseBashToolOperationRequest(input: makeInput([
            "operation": .string("start"),
            "command": .string("npm run dev"),
            "task_id": .string("dev-server"),
            "execution_mode": .string("detached")
        ]))

        #expect(request.operation == .start)
        #expect(request.taskId == "dev-server")
        #expect(request.command == "npm run dev")
        #expect(request.executionMode == .detached)
    }

    @Test func parseOperationInterruptRequestRequiresTaskId() async throws {
        let request = try ClaudeService().parseBashToolOperationRequest(input: makeInput([
            "operation": .string("interrupt"),
            "task_id": .string("task-1")
        ]))

        #expect(request.operation == .interrupt)
        #expect(request.taskId == "task-1")
    }

    @Test func parseOperationRejectsLegacyBackgroundFlag() async throws {
        await #expect(throws: BashToolOperationRouterError.self) {
            _ = try ClaudeService().parseBashToolOperationRequest(input: makeInput([
                "command": .string("npm run dev"),
                "background": .bool(true)
            ]))
        }
    }

    @Test func memoryWriteToolDescriptionMatchesUnifiedMemoryStore() async throws {
        let settings = AppSettings()
        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let memoryWrite = try #require(toolNamed("memory_write", in: tools))
        let description = try #require(encodedToolDictionary(from: memoryWrite)?["description"] as? String)

        #expect(description.contains("unified memory store"))
        #expect(!description.contains("~/.agentgui/memory.md"))
    }

    @Test func toolBuilderMarksToolsAsEphemeralForPromptCaching() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true
        settings.enableWebFetchTool = true
        settings.enableWebSearchTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)

        #expect(!tools.isEmpty)
        #expect(tools.allSatisfy { cacheControlType(from: $0) == "ephemeral" })
    }

    @Test func subagentWorkerBashSchemaMatchesUnifiedRegistry() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true
        settings.enableTextEditorTool = true
        let role = try #require(WorkflowRoleDefinition.find(named: "worker"))

        let tools = ClaudeService().makeSubagentToolsForTests(
            modelId: "claude-sonnet-4-6",
            definition: role,
            settings: settings
        )
        let bash = try #require(toolNamed("bash", in: tools))
        let propertyNames = schemaPropertyNames(from: bash)

        #expect(propertyNames.contains("execution_mode"))
        #expect(propertyNames.contains("task_id"))
        #expect(propertyNames.contains("operation"))
    }

    @Test func workflowWorkerBashSchemaMatchesUnifiedRegistry() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true
        settings.enableTextEditorTool = true
        let role = try #require(WorkflowRoleDefinition.find(named: "worker"))

        let tools = WorkflowAgentRunner.makeToolsForTests(
            role: role,
            settings: settings
        )
        let bash = try #require(toolNamed("bash", in: tools))
        let propertyNames = schemaPropertyNames(from: bash)

        #expect(propertyNames.contains("execution_mode"))
        #expect(propertyNames.contains("task_id"))
        #expect(propertyNames.contains("operation"))
    }

    private func toolNamed(_ name: String, in tools: [MessageParameter.Tool]) -> MessageParameter.Tool? {
        tools.first { toolName(from: $0) == name }
    }

    private func makeInput(_ values: [String: MessageResponse.Content.DynamicContent]) -> MessageResponse.Content.Input {
        values
    }

    private func toolName(from tool: MessageParameter.Tool) -> String? {
        encodedToolDictionary(from: tool)?["name"] as? String
    }

    private func schemaPropertyNames(from tool: MessageParameter.Tool) -> Set<String> {
        guard let inputSchema = encodedToolDictionary(from: tool)?["input_schema"] as? [String: Any],
              let properties = inputSchema["properties"] as? [String: Any] else {
            return []
        }

        return Set(properties.keys)
    }

    private func cacheControlType(from tool: MessageParameter.Tool) -> String? {
        (encodedToolDictionary(from: tool)?["cache_control"] as? [String: String])?["type"]
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