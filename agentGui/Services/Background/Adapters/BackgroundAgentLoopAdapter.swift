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
    private let authorizationResolver: ToolAuthorizationResolving
    private let toolsetProjector: AuthorizedToolsetProjector
    private let runtimeSettingsFactory: AuthorizedRuntimeSettingsFactory

    init(
        registry: any ToolRegistry = DefaultToolRegistry(),
        authorizationResolver: ToolAuthorizationResolving? = nil,
        toolsetProjector: AuthorizedToolsetProjector? = nil,
        runtimeSettingsFactory: AuthorizedRuntimeSettingsFactory = AuthorizedRuntimeSettingsFactory()
    ) {
        self.registry = registry
        self.authorizationResolver = authorizationResolver ?? ToolAuthorizationResolver(registry: registry)
        self.toolsetProjector = toolsetProjector ?? AuthorizedToolsetProjector(registry: registry)
        self.runtimeSettingsFactory = runtimeSettingsFactory
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
        let snapshot = authorizationSnapshot(task: task, settings: settings)
        return toolsetProjector.tools(from: snapshot)
    }

    func resolvedToolIDs(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> [String] {
        Array(authorizationSnapshot(task: task, settings: settings).allowedToolIDs).sorted()
    }

    func makeRuntimeSettings(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> AppSettings {
        runtimeSettingsFactory.makeRuntimeSettings(
            base: settings,
            snapshot: authorizationSnapshot(task: task, settings: settings),
            workingDirectory: task.workingDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? task.workingDirectoryPath ?? settings.workingDirectory
                : settings.workingDirectory,
            enabledSkillNames: settings.enabledSkillNames,
            autoStartLSPServers: settings.autoStartLSPServers
        )
    }

    private func authorizationSnapshot(
        task: BackgroundAgentTask,
        settings: AppSettings
    ) -> EffectiveToolAuthorizationSnapshot {
        let networkCeiling: ToolCapabilityLevel = settings.backgroundAgentAllowNetworkTools ? .observe : .disabled
        return authorizationResolver.resolve(
            ToolAuthorizationRequest(
                context: .backgroundTask,
                settings: settings,
                subjectPolicy: task.authorizationPolicy,
                capabilityCeilings: [.network: networkCeiling]
            )
        )
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