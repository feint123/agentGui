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

    private func toolNamed(_ name: String, in tools: [MessageParameter.Tool]) -> MessageParameter.Tool? {
        tools.first { toolName(from: $0) == name }
    }

    private func makeInput(_ values: [String: MessageResponse.Content.DynamicContent]) -> MessageResponse.Content.Input {
        values
    }

    private func toolName(from tool: MessageParameter.Tool) -> String? {
        extractString(labeled: "name", from: Mirror(reflecting: tool))
    }

    private func schemaPropertyNames(from tool: MessageParameter.Tool) -> Set<String> {
        extractPropertyNames(from: Mirror(reflecting: tool))
    }

    private func extractString(labeled target: String, from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == target, let value = child.value as? String {
                return value
            }

            let childMirror = Mirror(reflecting: child.value)
            if let value = extractString(labeled: target, from: childMirror) {
                return value
            }
        }

        return nil
    }

    private func extractPropertyNames(from mirror: Mirror) -> Set<String> {
        var names: Set<String> = []

        for child in mirror.children {
            if child.label == "properties" {
                names.formUnion(collectStringKeys(from: Mirror(reflecting: child.value)))
            }

            names.formUnion(extractPropertyNames(from: Mirror(reflecting: child.value)))
        }

        return names
    }

    private func collectStringKeys(from mirror: Mirror) -> Set<String> {
        var names: Set<String> = []

        for child in mirror.children {
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.displayStyle == .tuple {
                let tupleChildren = Array(childMirror.children)
                if let key = tupleChildren.first?.value as? String {
                    names.insert(key)
                }
            }

            names.formUnion(collectStringKeys(from: childMirror))
        }

        return names
    }
}