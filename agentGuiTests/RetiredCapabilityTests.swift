import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct RetiredCapabilityTests {

    @Test func retiredStoryMemoryToolsStayAbsentFromMainAgent() async throws {
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true
        settings.enableWebSearchTool = true
        settings.enableWebFetchTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let names = Set(tools.compactMap(toolName(from:)))

        #expect(!names.contains("story_memory_query"))
        #expect(!names.contains("story_memory_upsert_character"))
        #expect(!names.contains("story_memory_verify_continuity"))
    }

    @Test func retiredStoryMemoryToolsStayAbsentFromWorkerSubagent() async throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "worker"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let tools = ClaudeService().makeSubagentToolsForTests(
            modelId: "claude-sonnet-4-6",
            definition: role,
            settings: settings
        )
        let names = Set(tools.compactMap(toolName(from:)))

        #expect(!names.contains("story_memory_query"))
        #expect(!names.contains("story_memory_upsert_character"))
        #expect(!names.contains("story_memory_verify_continuity"))
    }

    @Test func systemPromptOmitsRetiredStoryMemoryLanguage() async throws {
        let prompt = ClaudeService().makeSystemPromptForTests(
            skills: [],
            workingDirectory: "/tmp/repo",
            settings: AppSettings(),
            session: nil
        )

        #expect(prompt.contains("explore"))
        #expect(prompt.contains("worker"))
        #expect(prompt.contains("verifier"))
        #expect(!prompt.contains("creative_memory_manager"))
        #expect(!prompt.localizedLowercase.contains("story memory"))
        #expect(!prompt.contains("story_memory_"))
    }

    @Test func toolRegistryDoesNotPublishRetiredStoryMemoryDefinitions() async throws {
        let ids = Set(DefaultToolRegistry().allDefinitions().map(\.id))

        #expect(!ids.contains("story_memory_query"))
        #expect(!ids.contains("story_memory_upsert_character"))
        #expect(!ids.contains("story_memory_verify_continuity"))
    }

    @Test func settingsAndSessionsDoNotExposeRetiredStoryMemoryState() async throws {
        let settingsPropertyNames = Set(Mirror(reflecting: AppSettings()).children.compactMap(\.label))
        let sessionPropertyNames = Set(Mirror(reflecting: Session()).children.compactMap(\.label))

        #expect(!settingsPropertyNames.contains("enableStoryMemory"))
        #expect(!settingsPropertyNames.contains("storyMemoryAutoExtract"))
        #expect(!settingsPropertyNames.contains("storyMemoryPromptBudget"))
        #expect(!settingsPropertyNames.contains("storyMemoryProjectMode"))
        #expect(!sessionPropertyNames.contains("activeWritingProjectId"))
    }

    private func toolName(from tool: MessageParameter.Tool) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(tool),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json["name"] as? String
    }
}