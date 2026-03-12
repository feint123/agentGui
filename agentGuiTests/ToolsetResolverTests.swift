import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct ToolsetResolverTests {

    @Test func resolverExcludesWebSearchWhenDisabledInSettings() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "explorer"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableWebSearchTool = false
        settings.enableWebFetchTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(!result.toolIDs.contains("web_search"))
        #expect(result.toolIDs.contains("web_fetch"))
        #expect(result.excludedToolIDs.contains("web_search"))
    }

    @Test func resolverExposesStoryMemoryToolsForCreativeMemoryManager() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "creative_memory_manager"))
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("story_memory_query"))
        #expect(result.toolIDs.contains("story_memory_verify_continuity"))
        #expect(result.toolIDs.contains("story_memory_upsert_character"))
        #expect(!result.toolIDs.contains("bash"))
        #expect(!result.toolIDs.contains("str_replace_based_edit_tool"))
    }

    @Test func resolverBuildsReadOnlyToolsetForVerifier() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "verifier"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(!result.toolIDs.contains("bash"))
        #expect(!result.toolIDs.contains("run_subagent"))
    }
}