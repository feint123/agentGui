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
        #expect(propertyNames.contains("signal"))
        #expect(propertyNames.contains("goal_hint"))
        #expect(propertyNames.contains("scan_policy"))
        #expect(propertyNames.contains("auto_reply_policy"))
    }

    @Test func normalizeLegacyBackgroundInputMapsToManagedRequest() async throws {
        let request = try ClaudeService().normalizeBashToolRequest(input: makeInput([
            "command": .string("npm run dev"),
            "background": .bool(true),
            "goal_hint": .string("启动开发服务器")
        ]))

        #expect(request.command == "npm run dev")
        #expect(request.executionMode == .background)
        #expect(request.signal == nil)
        #expect(request.goalHint == "启动开发服务器")
        #expect(request.scanPolicy == .adaptive)
    }

    @Test func normalizeLegacyInteractiveInputMapsToManagedRequest() async throws {
        let request = try ClaudeService().normalizeBashToolRequest(input: makeInput([
            "command": .string("git commit"),
            "interactive": .bool(true),
            "input": .string("feat: test")
        ]))

        #expect(request.command == "git commit")
        #expect(request.executionMode == .interactive)
        #expect(request.input == "feat: test")
    }

    @Test func normalizeInterruptInputMapsToSignal() async throws {
        let request = try ClaudeService().normalizeBashToolRequest(input: makeInput([
            "interrupt": .bool(true)
        ]))

        #expect(request.command == nil)
        #expect(request.signal == .interrupt)
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