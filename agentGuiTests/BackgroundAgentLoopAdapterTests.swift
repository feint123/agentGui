import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundAgentLoopAdapterTests {
    @Test func adapterBuildsRestrictedAgentLoopRequest() throws {
        let adapter = BackgroundAgentLoopAdapter()
        let task = BackgroundAgentTask.fixture(taskPrompt: "检查仓库")
        task.modelIDOverride = "claude-background"
        var executionPolicy = task.executionPolicy
        executionPolicy.maxTurns = 4
        task.executionPolicy = executionPolicy

        let request = adapter.makeRequest(
            task: task,
            service: AnthropicServiceFactory.service(apiKey: "test-key", betaHeaders: nil),
            systemPrompt: "capsule"
        )

        #expect(request.modelId == "claude-background")
        #expect(request.maxRounds == 4)
        #expect(request.toolExecutionContext == .backgroundTask)
        #expect(request.runSource == "backgroundTask")
        #expect(request.requestedBudgetSeconds == task.executionPolicy.maxExecutionSeconds)
    }

    @Test func observeOnlyTrustTierStripsWriteAndShellTools() throws {
        let adapter = BackgroundAgentLoopAdapter()
        let task = BackgroundAgentTask.fixture(taskPrompt: "检查仓库")
        task.authorizationPolicy = ToolAuthorizationPolicy(preset: .observeOnly)
        let settings = AppSettings.testFixture()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true
        settings.enableWebSearchTool = true
        settings.enableWebFetchTool = true
        settings.backgroundAgentAllowNetworkTools = true

        let toolIDs = adapter.resolvedToolIDs(task: task, settings: settings)
        let runtimeSettings = adapter.makeRuntimeSettings(task: task, settings: settings)

        #expect(toolIDs == ["read_tool_payload", "web_fetch", "web_search"])
        #expect(runtimeSettings.enableTextEditorTool == false)
        #expect(runtimeSettings.enableBashTool == false)
        #expect(runtimeSettings.enableWebSearchTool == true)
        #expect(runtimeSettings.memoryEnabled == false)
    }

    @Test func actLimitedTrustTierAllowsWebToolsOnlyWhenBothTaskAndGlobalSwitchEnableThem() throws {
        let adapter = BackgroundAgentLoopAdapter()
        let task = BackgroundAgentTask.fixture(taskPrompt: "检查仓库")
        task.authorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)
        let settings = AppSettings.testFixture()
        settings.enableTextEditorTool = true
        settings.enableBashTool = true
        settings.enableWebSearchTool = true
        settings.enableWebFetchTool = true
        settings.backgroundAgentAllowNetworkTools = false

        let deniedToolIDs = adapter.resolvedToolIDs(task: task, settings: settings)
        settings.backgroundAgentAllowNetworkTools = true
        let allowedToolIDs = adapter.resolvedToolIDs(task: task, settings: settings)

        #expect(deniedToolIDs == ["bash", "read_tool_payload", "str_replace_based_edit_tool"])
        #expect(allowedToolIDs == ["bash", "read_tool_payload", "str_replace_based_edit_tool", "web_fetch", "web_search"])
    }
}