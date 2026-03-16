//
//  ClaudeService+AgenticLoop.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    private var perfLog: PerformanceMonitor.Type { PerformanceMonitor.self }

    func runAgenticLoop(
        apiMessages: [MessageParameter.Message],
        assistantMessage: Message,
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        systemPrompt: String = "",
        session: Session,
        settings: AppSettings,
        modelContext: ModelContext,
        maxRounds: Int = 500
    ) async throws -> AgentLoopRunResult {
        let loopSpan = perfLog.startSpan("AgenticLoop", category: "Loop", level: .verbose)
        defer { loopSpan.end() }

        var loopMessages = apiMessages
        let system = makeEphemeralSystemPrompt(systemPrompt)
        let request = AgentLoopRunRequest(
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            maxRounds: maxRounds,
            toolExecutionContext: .mainAgent,
            runSource: "mainAgent",
            runLabel: assistantMessage.textContent,
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: session,
            sessionId: session.sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0, message: assistantMessage) },
            parentMessage: assistantMessage,
            streamProjectionTarget: .message(assistantMessage),
            toolInterceptor: nil
        )
        let result = try await runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
        let saveSpan = perfLog.startSpan("FinalSave", category: "Database")
        try? modelContext.save()
        saveSpan.end()
        return result
    }

    // MARK: - Core Loop

    /// Shared agentic loop used by both the main agent and sub-agents.
    ///
    /// Callers parameterise per-call behaviour via:
    /// - `makeRound`: constructs the `AgentRound` for each iteration; the main agent
    ///   attaches it to a `Message`, sub-agents attach it to a `ToolCall`.
    /// - `parentMessage`: the `Message` to update on error/truncation; `nil` for
    ///   sub-agents (they use the return value instead).
    /// - `streamProjectionTarget`: describes how accumulated output should be projected
    ///   to UI or workflow status consumers without embedding callback logic in the loop.
    ///
    /// Returns the full accumulated text produced across all rounds.
    @discardableResult
    func runCoreAgentLoop(
        messages: inout [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String,
        tools: [MessageParameter.Tool],
        system: MessageParameter.System?,
        settings: AppSettings,
        session: Session? = nil,
        sessionId: String,
        modelContext: ModelContext,
        maxRounds: Int,
        makeRound: @escaping (Int) -> AgentRound,
        parentMessage: Message?,
        streamProjectionTarget: AgentLoopStreamProjectionTarget = .none,
        toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)? = nil,
        toolExecutionContext: ToolContext = .mainAgent
    ) async throws -> AgentLoopRunResult {
        let request = AgentLoopRunRequest(
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            maxRounds: maxRounds,
            toolExecutionContext: toolExecutionContext,
            runSource: toolExecutionContext == .backgroundTask ? "backgroundTask" : "coreLoop",
            runLabel: nil,
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: session,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: makeRound,
            parentMessage: parentMessage,
            streamProjectionTarget: streamProjectionTarget,
            toolInterceptor: toolInterceptor
        )
        return try await runCoreAgentLoop(messages: &messages, request: request, runtime: runtime)
    }

    @discardableResult
    func runCoreAgentLoop(
        messages: inout [MessageParameter.Message],
        request: AgentLoopRunRequest,
        runtime: AgentLoopRuntime
    ) async throws -> AgentLoopRunResult {
        let initialState = AgentLoopRunState()
        let bootstrapMessagesSnapshot = messages

        let hookFactory = AgentLoopBuiltInHookFactory()
        let hookDependencies = AgentLoopHookDependencyFactory(
            claudeService: self,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: bootstrapMessagesSnapshot
        ).build(state: initialState.hookState)
        let hookDispatcher = AgentLoopHookDispatcher(
            hooks: hookFactory.makeHooks(dependencies: hookDependencies, state: initialState.hookState)
        )
        let toolExecutionCoordinator = AgentLoopToolExecutionCoordinatorBuilder(
            claudeService: self,
            service: request.service,
            modelId: request.modelId,
            settings: runtime.settings,
            sessionId: runtime.sessionId,
            modelContext: runtime.modelContext
        ).build()
        let sharedState = AgentLoopSharedStateAccess(
            readVerification: { self.sessionVerifications[$0] },
            writeVerification: { self.sessionVerifications[$0] = $1 },
            readExecutionEvidence: { self.sessionExecutionEvidence[$0] ?? [] },
            writeExecutionEvidence: { self.sessionExecutionEvidence[$0] = $1 },
            readEpistemicInputs: { self.sessionEpistemicInputs[$0] ?? [] },
            writeEpistemicInputs: { self.sessionEpistemicInputs[$0] = $1 },
            setCurrentModelId: { self.currentModelId = $0 },
            setCurrentInputTokens: { self.currentInputTokens = $0 }
        )
        let emitter = AgentLoopHookEmitter(
            dispatcher: hookDispatcher,
            request: request,
            runtime: runtime,
            businessLogSink: businessLogSink
        )
        let runner = AgentLoopRunner(
            claudeService: self,
            request: request,
            runtime: runtime,
            sharedState: sharedState,
            emitter: emitter,
            toolExecutionCoordinator: toolExecutionCoordinator,
            initialState: initialState
        )
        return try await runner.run(messages: &messages)
    }

    @MainActor
    func buildUnifiedMemoryBootstrap(
        settings: AppSettings,
        session: Session?,
        sessionId: String,
        messages: [MessageParameter.Message],
        modelContext: ModelContext,
        insightStore: (any RMSInsightStoring)? = nil
    ) async throws -> RMSMemoryRuntimeContext? {
        guard settings.memoryEnabled else { return nil }
        guard !sessionId.isEmpty else { return nil }
        let resolvedInsightStore = insightStore ?? RMSInsightStore()

        let resolvedSession: Session?
        if let session {
            resolvedSession = session
        } else {
            let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.sessionId == sessionId })
            resolvedSession = try modelContext.fetch(descriptor).first
        }

        let currentRequest = messages.reversed()
            .first(where: { $0.role == "user" })
            .map { extractText(from: $0.content) } ?? ""

        let taskStateStore = SessionTaskStateStore(
            modelContext: modelContext,
            persistenceCoordinator: .shared
        )
        let bootstrapState = taskStateStore.rmsState(for: sessionId)

        let composition = try await AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: { bootstrapState },
                loadInsights: { state in
                    try resolvedInsightStore.load(
                        scopes: self.insightScopes(
                            for: state,
                            session: resolvedSession,
                            settings: settings,
                            fallbackSessionID: sessionId
                        )
                    )
                }
            )
        ).compose(
            bootstrapMessageCount: messages.count,
            insightBudget: normalizedInsightBudget(from: settings)
        )
        guard let renderedPrompt = composition.patch?.insertions.first.map({ extractText(from: $0.message.content) }),
              !renderedPrompt.isEmpty else {
            return nil
        }

        BusinessMonitor.emit(
            .memoryContextPrepared,
            context: .init(sessionID: sessionId),
            metadata: [
                "source": "rms",
                "frontierCount": bootstrapState?.frontiers.count ?? 0,
                "constraintCount": bootstrapState?.constraints.count ?? 0,
                "verificationDebtCount": bootstrapState?.verificationDebts.count ?? 0,
                "contextBudget": max(settings.memoryContextBudget * 1000, 4000)
            ],
            sink: businessLogSink
        )

        return RMSMemoryRuntimeContext(
            profiles: ["rms"],
            records: [],
            writePolicy: .readMostly,
            warnings: composition.runtimeWarnings,
            renderedPrompt: renderedPrompt
        )
    }

    private func insightScopes(
        for state: RMSState?,
        session: Session?,
        settings: AppSettings,
        fallbackSessionID: String
    ) -> [MemoryScope] {
        let workspaceRoot = [session?.workingDirectory, settings.workingDirectory]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let sessionID = [state?.sessionID, fallbackSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let threadID = state?.threadID.trimmingCharacters(in: .whitespacesAndNewlines)

        var scopes: [MemoryScope] = [.user]
        if let sessionID {
            scopes.append(.session(id: sessionID))
        }
        if let threadID, !threadID.isEmpty {
            scopes.append(.thread(id: threadID))
        }
        if let workspaceRoot {
            scopes.append(.workspace(id: workspaceRoot))
        }

        var seen: Set<String> = []
        return scopes.filter { seen.insert($0.namespace).inserted }
    }

    private func normalizedInsightBudget(from settings: AppSettings) -> Int {
        max(1, settings.memoryContextBudget / 4)
    }

    func payloadReadRangeSummary(from input: MessageResponse.Content.Input) -> String? {
        guard input["payload_ref"]?.stringValue != nil else { return nil }
        if let cursor = input["cursor"]?.stringValue, !cursor.isEmpty {
            return cursor
        }
        let readMode = input["read_mode"]?.stringValue ?? "chunk"
        if let start = input["start"]?.intValue,
           let end = input["end"]?.intValue {
            return "\(readMode):\(start)-\(end)"
        }
        return readMode
    }

    /// Returns true if the model supports Extended Thinking (3.7 Sonnet and all later models)
    func isThinkingCapable(modelId: String) -> Bool {
        // Claude 3.7+ and all Claude 4 series support Extended Thinking
        let thinkingModels = ["claude-3-7", "claude-3.7", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        return thinkingModels.contains { modelId.contains($0) }
    }

}
