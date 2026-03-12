import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct ToolsetResolverTests {

    @Test func resolverExcludesWebSearchWhenDisabledInSettings() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "explore"))
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

    @Test func resolverExposesEditorAndShellToolsForWorker() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "worker"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(result.toolIDs.contains("bash"))
        #expect(!result.toolIDs.contains("story_memory_query"))
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