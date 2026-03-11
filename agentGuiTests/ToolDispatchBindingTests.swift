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

    @Test func registryIncludesWorkflowArtifactToolDefinition() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "emit_workflow_artifact"))

        #expect(definition.executorKey == "workflow.emitArtifact")
        #expect(definition.supportedContexts.contains(.workflowWorker))
    }
}