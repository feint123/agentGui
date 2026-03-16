import Foundation
import SwiftAnthropic
import SwiftData

struct BackgroundExecutionOutcome: Equatable, Sendable {
    var textOutput: String
    var resultSummary: String
}

@MainActor
protocol BackgroundAgentLoopAdapting {
    func execute(
        task: BackgroundAgentTask,
        prompt: String,
        service: any AnthropicService,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome
}

@MainActor
struct BackgroundAgentLoopAdapter: BackgroundAgentLoopAdapting {
    private let registry: any ToolRegistry

    init(registry: any ToolRegistry = DefaultToolRegistry()) {
        self.registry = registry
    }

    func makeRequest(
        task: BackgroundAgentTask,
        service: any AnthropicService,
        systemPrompt: String,
        tools: [MessageParameter.Tool] = []
    ) -> AgentLoopRunRequest {
        let policy = task.executionPolicy
        return AgentLoopRunRequest(
            service: service,
            modelId: task.modelIDOverride ?? "claude-sonnet-4-6",
            tools: tools,
            system: makeEphemeralSystemPrompt(systemPrompt),
            maxRounds: policy.maxTurns,
            toolExecutionContext: .backgroundTask,
            runSource: "backgroundTask",
            runLabel: task.title,
            requestedBudgetSeconds: policy.maxExecutionSeconds
        )
    }

    func execute(
        task: BackgroundAgentTask,
        prompt: String,
        service: any AnthropicService,
        modelContext: ModelContext
    ) async throws -> BackgroundExecutionOutcome {
        let claudeService = ClaudeService()
        let baseSettings = AppSettings.getOrCreate(in: modelContext)
        let settings = makeRuntimeSettings(task: task, settings: baseSettings)
        let session = try resolveSession(id: task.sessionId, modelContext: modelContext)
        let originalWorkingDirectory = session.workingDirectory
        session.workingDirectory = settings.workingDirectory
        defer {
            session.workingDirectory = originalWorkingDirectory
        }
        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text(prompt))
        ]
        let request = makeRequest(
            task: task,
            service: service,
            systemPrompt: task.systemPromptOverride ?? "",
            tools: buildTools(task: task, settings: settings)
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: session,
            sessionId: task.sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )
        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            request: request,
            runtime: runtime
        )
        return BackgroundExecutionOutcome(
            textOutput: result.text,
            resultSummary: result.completedSuccessfully ? "completed" : (result.terminationReason ?? "failed")
        )
    }

    func buildTools(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> [MessageParameter.Tool] {
        resolvedToolIDs(task: task, settings: settings).compactMap { toolID in
            guard let definition = registry.definition(for: toolID),
                  definition.supportedContexts.contains(.backgroundTask),
                  isEnabled(toolID: toolID, settings: settings) else {
                return nil
            }
            return definition.makeAnthropicTool()
        }
    }

    func resolvedToolIDs(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> [String] {
        var toolIDs = ["read_tool_payload"]
        let policy = task.toolGrantPolicy.effectivePolicy(
            backgroundNetworkToolsEnabled: settings.backgroundAgentAllowNetworkTools
        )

        if policy.allowFileWrite {
            toolIDs.append("str_replace_based_edit_tool")
        }

        if policy.allowBash {
            toolIDs.append("bash")
        }

        if policy.allowNetworkAccess {
            toolIDs.append(contentsOf: ["web_search", "web_fetch"])
        }

        return Array(Set(toolIDs)).sorted()
    }

    func makeRuntimeSettings(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> AppSettings {
        let runtimeSettings = AppSettings()
        let effectivePolicy = task.toolGrantPolicy.effectivePolicy(
            backgroundNetworkToolsEnabled: settings.backgroundAgentAllowNetworkTools
        )

        runtimeSettings.apiKey = settings.apiKey
        runtimeSettings.baseURL = settings.baseURL
        runtimeSettings.selectedModel = settings.selectedModel
        runtimeSettings.themeMode = settings.themeMode
        runtimeSettings.messageFontSize = settings.messageFontSize
        runtimeSettings.enableTextEditorTool = settings.enableTextEditorTool && effectivePolicy.allowFileWrite
        runtimeSettings.enableBashTool = settings.enableBashTool && effectivePolicy.allowBash
        runtimeSettings.workingDirectory = task.workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? task.workingDirectoryPath ?? settings.workingDirectory
            : settings.workingDirectory
        runtimeSettings.enableExtendedThinking = settings.enableExtendedThinking
        runtimeSettings.extendedThinkingBudget = settings.extendedThinkingBudget
        runtimeSettings.enabledSkillNames = settings.enabledSkillNames
        runtimeSettings.enableWebSearchTool = settings.enableWebSearchTool && effectivePolicy.allowNetworkAccess
        runtimeSettings.enableWebFetchTool = settings.enableWebFetchTool && effectivePolicy.allowNetworkAccess
        runtimeSettings.enableLSPTools = false
        runtimeSettings.autoStartLSPServers = settings.autoStartLSPServers
        runtimeSettings.lspDefaultRoutingMode = settings.lspDefaultRoutingMode
        runtimeSettings.lspCustomServerProfiles = settings.lspCustomServerProfiles
        runtimeSettings.lspInstalledProviders = settings.lspInstalledProviders
        runtimeSettings.lspInstalledServerDefinitions = settings.lspInstalledServerDefinitions
        runtimeSettings.lspManualWorkspaceBindingsJSON = settings.lspManualWorkspaceBindingsJSON
        runtimeSettings.ollamaAPIKey = settings.ollamaAPIKey
        runtimeSettings.enableOllamaWebSearch = settings.enableOllamaWebSearch && effectivePolicy.allowNetworkAccess
        runtimeSettings.enableNetworkProxy = settings.enableNetworkProxy
        runtimeSettings.networkProxyURL = settings.networkProxyURL
        runtimeSettings.networkProxyBypassList = settings.networkProxyBypassList
        runtimeSettings.memoryEnabled = settings.memoryEnabled && effectivePolicy.allowMemoryMutation
        runtimeSettings.memoryContextBudget = settings.memoryContextBudget
        runtimeSettings.backgroundAgentEnabled = settings.backgroundAgentEnabled
        runtimeSettings.backgroundAgentDefaultQoS = settings.backgroundAgentDefaultQoS
        runtimeSettings.backgroundAgentRequiresExternalPower = settings.backgroundAgentRequiresExternalPower
        runtimeSettings.backgroundAgentAllowNetworkTools = settings.backgroundAgentAllowNetworkTools
        runtimeSettings.backgroundAgentMaximumConcurrentRuns = settings.backgroundAgentMaximumConcurrentRuns
        runtimeSettings.backgroundAgentObservationRetentionDays = settings.backgroundAgentObservationRetentionDays

        return runtimeSettings
    }

    private func isEnabled(toolID: String, settings: AppSettings) -> Bool {
        switch toolID {
        case "str_replace_based_edit_tool":
            return settings.enableTextEditorTool
        case "bash":
            return settings.enableBashTool
        case "web_search":
            return settings.enableWebSearchTool && settings.backgroundAgentAllowNetworkTools
        case "web_fetch":
            return settings.enableWebFetchTool && settings.backgroundAgentAllowNetworkTools
        default:
            return true
        }
    }

    private func resolveSession(id: String, modelContext: ModelContext) throws -> Session {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        guard let session = sessions.first(where: { $0.sessionId == id }) else {
            throw BackgroundSessionResultWriterError.sessionNotFound(id)
        }
        return session
    }

    private func makeEphemeralSystemPrompt(_ prompt: String) -> MessageParameter.System? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .list([
            .init(text: trimmed, cacheControl: .init(type: .ephemeral))
        ])
    }
}