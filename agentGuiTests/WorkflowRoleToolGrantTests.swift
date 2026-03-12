import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkflowRoleToolGrantTests {

    @Test func exploreRoleResolvesReadOnlyEditorWithoutShell() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "explore"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true
        settings.enableWebSearchTool = true
        settings.enableWebFetchTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(!result.toolIDs.contains("bash"))
        #expect(result.toolIDs.contains("web_search"))
        #expect(result.toolIDs.contains("web_fetch"))
    }

    @Test func workerRoleResolvesEditorAndShellTools() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "worker"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(result.toolIDs.contains("bash"))
    }

    @Test func verifierRoleResolvesReadOnlyEditorWithoutShell() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "verifier"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(!result.toolIDs.contains("bash"))
    }
}