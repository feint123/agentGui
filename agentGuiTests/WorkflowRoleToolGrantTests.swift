import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkflowRoleToolGrantTests {

    @Test func plannerRoleResolvesReadOnlyEditorWithoutShell() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "planner"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(!result.toolIDs.contains("bash"))
    }

    @Test func coderRoleResolvesEditorAndShellTools() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "coder"))
        let settings = AppSettings()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(result.toolIDs.contains("bash"))
    }
}