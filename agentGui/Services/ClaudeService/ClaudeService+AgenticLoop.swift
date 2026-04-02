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
            toolApprovalMode: SessionExecutionPreferencesResolver.builtInApprovalMode(for: session, settings: settings),
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

    func executeRemoteTurn(
        text: String,
        session: Session,
        runtimeSettings: AppSettings,
        modelContext: ModelContext,
        deliveryHandle: (any RemoteTurnDeliveryHandle)? = nil,
        maxRounds: Int
    ) async throws -> AgentLoopRunResult {
        guard let service else { throw ClaudeError.notConfigured }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        let lastPersistedMessageMatchesCurrentTurn = sortedMessages.last.map {
            $0.direction == .user && $0.textContent == text
        } ?? false
        if !lastPersistedMessageMatchesCurrentTurn {
            apiMessages.append(MessageParameter.Message(role: .user, content: .text(text)))
        }

        let turnSkillContext = try await resolveTurnSkillContext(
            enabledSkillNames: runtimeSettings.enabledSkillNames,
            directives: []
        )
        let systemPrompt = buildSystemPrompt(
            skills: turnSkillContext.effectiveSkills,
            explicitlyActivatedSkills: turnSkillContext.explicitlyActivatedSkills,
            workingDirectory: runtimeSettings.workingDirectory,
            settings: runtimeSettings
        )
        let tools = buildTools(
            modelId: runtimeSettings.selectedModel,
            settings: runtimeSettings,
            enabledSkills: turnSkillContext.effectiveSkills
        )
        let request = AgentLoopRunRequest(
            service: service,
            modelId: runtimeSettings.selectedModel,
            tools: tools,
            system: makeEphemeralSystemPrompt(systemPrompt),
            maxRounds: maxRounds,
            toolExecutionContext: .mainAgent,
            toolApprovalMode: .bypassApprovals,
            runSource: "remoteChannel",
            runLabel: text,
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: runtimeSettings,
            session: session,
            sessionId: session.sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            remoteDeliveryHandle: deliveryHandle
        )
        return try await runCoreAgentLoop(messages: &apiMessages, request: request, runtime: runtime)
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
            toolApprovalMode: .bypassApprovals,
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
            toolApprovalMode: request.toolApprovalMode,
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
            setCurrentModelId: { self.builtInExecutionContext(for: runtime.sessionId).currentModelID = $0 },
            setCurrentInputTokens: { self.builtInExecutionContext(for: runtime.sessionId).currentInputTokens = $0 },
            updateContextBudget: { [weak self] state in
                self?.builtInExecutionContext(for: runtime.sessionId).contextBudgetState = state
            }
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
