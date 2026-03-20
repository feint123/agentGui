import Foundation
import Testing
@testable import agentGui

@MainActor
struct ToolDispatchBindingTests {

    @Test func registryBackedExecutorKeyMapsToKnownDispatchPath() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "bash"))

        #expect(definition.executorKey == "builtin.bash")
    }

    @Test func registryNoLongerIncludesWorkflowArtifactToolDefinition() {
        let registry = DefaultToolRegistry()

        #expect(registry.definition(for: "emit_workflow_artifact") == nil)
    }

    @Test func registryIncludesLSPDefinitionToolBinding() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "lsp_definition"))

        #expect(definition.executorKey == "lsp.definition")
    }
}