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
        executionRequirement: ExecutionRequirement = .none,
        maxRounds: Int = 500
    ) async throws -> AgentLoopRunResult {
        let loopSpan = perfLog.startSpan("AgenticLoop", category: "Loop", level: .verbose)
        defer { loopSpan.end() }

        var loopMessages = apiMessages
        let system = makeEphemeralSystemPrompt(systemPrompt)
        let result = try await runCoreAgentLoop(
            messages: &loopMessages,
            service: service,
            modelId: modelId,
            tools: tools,
            system: system,
            settings: settings,
            session: session,
            sessionId: session.sessionId,
            modelContext: modelContext,
            maxRounds: maxRounds,
            makeRound: { AgentRound(roundIndex: $0, message: assistantMessage) },
            parentMessage: assistantMessage,
            streamProjectionTarget: .message(assistantMessage),
            executionRequirement: executionRequirement
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
        makeRound: (Int) -> AgentRound,
        parentMessage: Message?,
        streamProjectionTarget: AgentLoopStreamProjectionTarget = .none,
        toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)? = nil,
        executionRequirement: ExecutionRequirement = .none,
        toolExecutionContext: ToolContext = .mainAgent
    ) async throws -> AgentLoopRunResult {
        var accumulatedText = ""
        var loopCtx = AgentLoopContext(phase: .executing)
        var loopMemory = ContextMemory()
        let runID = UUID().uuidString
        var executionEvidence: Set<ExecutionEvidenceKind> = []
        var executionGuardRetryCount = 0
        let hookState = AgentLoopBuiltInHookFactory.State()
        let bootstrapMessagesSnapshot = messages

        func pendingToolID(from context: AgentLoopHookContext) -> String {
            (context.metadata["toolUseID"] as? String) ?? UUID().uuidString
        }

        func roundForToolContext(from context: AgentLoopHookContext, fallback: AgentRound?) -> AgentRound? {
            (context.metadata["agentRound"] as? AgentRound) ?? fallback
        }

        let hookFactory = AgentLoopBuiltInHookFactory()
        let hookDependencies = AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: businessLogSink,
            memoryBootstrapLoader: { state in
                let unifiedStore = UnifiedMemoryFileStoreAdapter()
                let composer = AgentLoopMemoryBootstrapComposer(
                    dependencies: .init(
                        loadUnifiedContext: {
                            try await self.buildUnifiedMemoryBootstrap(
                                settings: settings,
                                session: session,
                                sessionId: sessionId,
                                messages: bootstrapMessagesSnapshot,
                                modelContext: modelContext
                            )
                        },
                        loadTaskMemory: {
                            guard !sessionId.isEmpty else { return nil }
                            return try self.loadTaskMemory(sessionId: sessionId, store: unifiedStore)
                        },
                        loadTaskMemoryPromptText: {
                            guard !sessionId.isEmpty else { return nil }
                            return try self.taskMemoryPromptText(sessionId: sessionId, store: unifiedStore)
                        },
                        loadStorySlice: {
                            try self.buildStoryMemoryBootstrap(
                                settings: settings,
                                sessionId: sessionId,
                                messages: bootstrapMessagesSnapshot,
                                modelContext: modelContext
                            )
                        },
                        saveRuntimeSnapshot: { snapshot in
                            let snapshotStore = MemoryRuntimeSnapshotStore()
                            try snapshotStore.save(snapshot)
                            return snapshot.id
                        }
                    )
                )
                let composition = try await composer.compose(bootstrapMessageCount: bootstrapMessagesSnapshot.count)
                state.memoryRuntimeProfiles = composition.runtimeProfiles
                state.memoryRuntimeLayers = composition.runtimeLayers
                state.memoryRuntimeWarnings = composition.runtimeWarnings
                state.memoryRuntimeSnapshotID = composition.runtimeSnapshotID
                return composition.patch
            },
            createToolCallRecord: { context, state in
                let record = self.makeToolCallRecord(
                    toolUseId: pendingToolID(from: context),
                    toolName: context.pendingToolName ?? "unknown",
                    input: context.toolInput,
                    message: parentMessage,
                    agentRound: roundForToolContext(from: context, fallback: state.lastRound),
                    executionContext: toolExecutionContext
                )
                if !state.memoryRuntimeProfiles.isEmpty {
                    record.memoryRuntimeProfiles = state.memoryRuntimeProfiles
                }
                if !state.memoryRuntimeLayers.isEmpty {
                    record.memoryRuntimeLayers = state.memoryRuntimeLayers
                }
                if !state.memoryRuntimeWarnings.isEmpty {
                    record.memoryRuntimeWarnings = state.memoryRuntimeWarnings
                }
                if let memoryRuntimeSnapshotID = state.memoryRuntimeSnapshotID,
                   !memoryRuntimeSnapshotID.isEmpty {
                    record.memoryRuntimeSnapshotID = memoryRuntimeSnapshotID
                }
                modelContext.insert(record)
                try? modelContext.save()
                return record
            },
            updateToolCallRecord: { context, _ in
                guard let record = context.toolCallRecord else { return }
                if let preview = context.metadata["toolResultPreview"] as? String, !preview.isEmpty {
                    record.terminalOutput = preview
                } else {
                    record.terminalOutput = context.toolResultText
                }
                record.toolResultSummary = context.metadata["toolResultSummary"] as? String
                record.toolPayloadRef = context.metadata["toolPayloadRef"] as? String
                record.toolResultRawChars = context.metadata["toolResultRawChars"] as? Int
                record.toolResultInjectedChars = context.metadata["toolResultInjectedChars"] as? Int
                record.toolResultInjectionMode = context.metadata["toolResultInjectionMode"] as? String
                record.toolPayloadLastReadRange = context.metadata["toolPayloadLastReadRange"] as? String
                if let payloadReadCount = context.metadata["toolPayloadReadCount"] as? Int {
                    record.toolPayloadReadCount = payloadReadCount
                }
                if let status = context.metadata["toolStatus"] as? ToolStatus {
                    record.status = status
                }
                record.endTime = Date()
                try? modelContext.save()
            },
            reflectionResolver: { context, state in
                let reflection = await self.reflectOnRound(
                    messages: context.messagesSnapshot,
                    service: service,
                    modelId: modelId,
                    settings: settings,
                    failureTrigger: context.failureTrigger
                )

                guard let reflection else {
                    return AgentLoopReflectionResolution(shouldRetry: false, correctionPrompt: nil)
                }

                if let round = state.lastRound {
                    round.reflectionConfidence = reflection.confidence
                    round.reflectionConcerns = reflection.concerns
                    round.reflectionSuggestedFixes = reflection.suggestedFixes
                    round.reflectionShouldRetry = reflection.shouldRetry
                    try? modelContext.save()
                }

                if (!reflection.concerns.isEmpty || !reflection.suggestedFixes.isEmpty), !sessionId.isEmpty {
                    try? self.recordReflectionFailure(
                        sessionId: sessionId,
                        trigger: context.failureTrigger,
                        concerns: reflection.concerns,
                        suggestedFixes: reflection.suggestedFixes
                    )
                }

                let correctionPrompt: String?
                if reflection.shouldRetry && !reflection.suggestedFixes.isEmpty {
                    let triggerContext = context.failureTrigger.map { "Triggered by: \($0.description)\n\n" } ?? ""
                    let fixList = reflection.suggestedFixes
                        .enumerated()
                        .map { "\($0.offset + 1). \($0.element)" }
                        .joined(separator: "\n")
                    correctionPrompt = """
                        \(triggerContext)A failure was detected and analysed. \
                        Please address the following corrections before retrying:\n\(fixList)
                        """
                } else {
                    correctionPrompt = nil
                }

                return AgentLoopReflectionResolution(
                    shouldRetry: reflection.shouldRetry,
                    correctionPrompt: correctionPrompt
                )
            }
        )
        let hookDispatcher = AgentLoopHookDispatcher(
            hooks: hookFactory.makeHooks(dependencies: hookDependencies, state: hookState)
        )
        let toolExecutionCoordinator = AgentLoopToolExecutionCoordinatorBuilder(
            claudeService: self,
            service: service,
            modelId: modelId,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        ).build()

        func dispatchHooks(
            _ stage: AgentLoopHookStage,
            metadata: [String: Any] = [:],
            toolName: String? = nil,
            projectedText: String? = nil,
            currentRoundText: String = "",
            currentRoundThinking: String = "",
            toolInput: MessageResponse.Content.Input = [:],
            toolResultText: String = "",
            toolCallRecord: ToolCall? = nil
        ) async -> AgentLoopHookDispatchResult {
            var context = AgentLoopHookContext(
                runID: runID,
                sessionID: sessionId,
                workflowID: nil,
                executionContext: toolExecutionContext,
                modelId: modelId,
                roundIndex: loopCtx.roundIndex,
                phase: loopCtx.phase.label
            )
            context.pendingToolName = toolName
            context.stopReason = loopCtx.lastStopReason
            context.failureTrigger = loopCtx.pendingFailureTrigger
            context.accumulatedText = projectedText ?? accumulatedText
            context.currentRoundText = currentRoundText.isEmpty
                ? currentRoundTextForHook(projectedText: projectedText)
                : currentRoundText
            context.currentRoundThinking = currentRoundThinking
            context.messagesSnapshot = messages
            context.metadata = metadata
            context.streamProjectionTarget = streamProjectionTarget
            context.toolInput = toolInput
            context.toolResultText = toolResultText
            context.toolCallRecord = toolCallRecord
            return (try? await hookDispatcher.dispatch(stage, context: context)) ?? AgentLoopHookDispatchResult()
        }

        func emitHook(
            _ stage: AgentLoopHookStage,
            metadata: [String: Any] = [:],
            toolName: String? = nil,
            projectedText: String? = nil,
            currentRoundText: String = "",
            currentRoundThinking: String = "",
            toolInput: MessageResponse.Content.Input = [:],
            toolResultText: String = "",
            toolCallRecord: ToolCall? = nil
        ) async {
            _ = await dispatchHooks(
                stage,
                metadata: metadata,
                toolName: toolName,
                projectedText: projectedText,
                currentRoundText: currentRoundText,
                currentRoundThinking: currentRoundThinking,
                toolInput: toolInput,
                toolResultText: toolResultText,
                toolCallRecord: toolCallRecord
            )
        }

        func currentRoundTextForHook(projectedText: String?) -> String {
            projectedText ?? accumulatedText
        }

        await emitHook(
            .didStartRun,
            metadata: [
                "modelId": modelId,
                "maxRounds": maxRounds,
                "messageCount": messages.count
            ]
        )

        if let bootstrapResult = try? await hookDispatcher.dispatch(
            .prepareRun,
            context: AgentLoopHookContext(
                runID: runID,
                sessionID: sessionId,
                workflowID: nil,
                executionContext: toolExecutionContext,
                modelId: modelId,
                roundIndex: loopCtx.roundIndex,
                phase: loopCtx.phase.label,
                messagesSnapshot: messages,
                metadata: [:],
                streamProjectionTarget: streamProjectionTarget
            )
        ),
        let patch = bootstrapResult.messagePatch,
        !patch.insertions.isEmpty {
            for insertion in patch.insertions.sorted(by: { $0.index < $1.index }) {
                messages.insert(insertion.message, at: min(insertion.index, messages.count))
            }
            if !patch.metadata.isEmpty {
                await emitHook(.didApplyBootstrap, metadata: patch.metadata)
            }
        }
        while loopCtx.shouldContinue && loopCtx.roundIndex < maxRounds {
            try Task.checkCancellation()

            // Reflection phase runs without a new streaming API call.
            // It must be handled here, before the streaming block, so that
            // loopCtx.transition(stopReason:) cannot overwrite the phase.
            if loopCtx.phase == .reflecting {
                let trigger = loopCtx.pendingFailureTrigger
                await emitHook(
                    .willStartReflection,
                    metadata: [
                        "reflectionPass": loopCtx.reflectionCount + 1,
                        "trigger": trigger?.description ?? "none"
                    ]
                )
                let reflectionHooks = await dispatchHooks(
                    .processReflection,
                    metadata: [
                        "reflectionPass": loopCtx.reflectionCount + 1,
                        "trigger": trigger?.description ?? "none"
                    ]
                )
                // Consume the failure trigger regardless of reflection outcome
                loopCtx.pendingFailureTrigger = nil

                if let resolution = reflectionHooks.reflectionResolution {
                    if let correctionPrompt = resolution.correctionPrompt {
                        messages.append(.init(role: .user, content: .text(correctionPrompt)))
                    }
                    await emitHook(
                        .didCompleteReflection,
                            metadata: [
                                "shouldRetry": resolution.shouldRetry,
                                "hasCorrectionPrompt": resolution.correctionPrompt != nil
                            ]
                        )
                    loopCtx.reflectionComplete(shouldRetry: resolution.shouldRetry)
                } else {
                    await emitHook(
                        .didCompleteReflection,
                            metadata: [
                                "result": "missing",
                                "shouldRetry": false
                            ]
                        )
                    loopCtx.reflectionComplete(shouldRetry: false)
                }
                continue
            }

            await emitHook(
                .willStartRound,
                metadata: [
                    "messageCount": messages.count,
                    "phase": loopCtx.phase.label,
                    "modelId": modelId
                ]
            )
            let accumulatedTextBeforeRound = accumulatedText

            let roundSpan = perfLog.startSpan("Round_\(loopCtx.roundIndex)", category: "Loop", level: .normal)

            await compressIfNeeded(
                messages: &messages,
                memory: &loopMemory,
                service: service,
                modelId: modelId,
                sessionId: sessionId
            )

            currentModelId = modelId
            let useThinking = settings.enableExtendedThinking && isThinkingCapable(modelId: modelId)
            let budget = settings.extendedThinkingBudget
            // thinking budget must be < maxTokens; give at least 4096 for response
            let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192

            let params = MessageParameter(
                model: .other(modelId),
                messages: messages,
                maxTokens: maxTokens,
                system: system,
                tools: tools.isEmpty ? nil : tools,
                thinking: useThinking ? .init(budgetTokens: budget) : nil
            )

            // Count input tokens before streaming (reliable: countTokens API always returns input_tokens)
            if let tokenCount = try? await service.countTokens(
                parameter: MessageTokenCountParameter(
                    model: .other(modelId),
                    messages: messages,
                    system: system,
                    tools: tools.isEmpty ? nil : tools
                )
            ) {
                currentInputTokens = tokenCount.inputTokens
            }

            let stream = try await service.streamMessage(params)
            let roundIdx = loopCtx.nextRound()

            let streamSpan = perfLog.startSpan("StreamRound_\(roundIdx)", category: "API", level: .normal)

            let round = makeRound(roundIdx)
            hookState.lastRound = round
            modelContext.insert(round)
            try? modelContext.save()

            var streamAssembler = AgentLoopRoundStreamAssembler()
            var deltaCount = 0

            for try await event in stream {
                let delta = streamAssembler.consume(event)
                let snapshot = streamAssembler.snapshot

                switch delta {
                case .text(let text):
                    let deltaSpan = perfLog.startSpan("text_delta", category: "Stream", level: .verbose)
                    deltaSpan.addMetadata("bytes", value: text.count)
                    deltaSpan.end()

                    let joined = accumulatedText.isEmpty
                        ? snapshot.text
                        : accumulatedText + "\n\n" + snapshot.text
                    await emitHook(
                        .didReceiveTextDelta,
                        metadata: [
                            "length": joined.count,
                            "agentRound": round
                        ],
                        projectedText: joined,
                        currentRoundText: snapshot.text
                    )

                    deltaCount += 1
                    perfLog.streamStats.recordDelta(text.count, round: roundIdx)

                case .thinking:
                    await emitHook(
                        .didReceiveThinkingDelta,
                        metadata: ["agentRound": round],
                        currentRoundThinking: snapshot.thinkingContent
                    )

                case .signature(let signature):
                    round.thinkingSignature = signature

                case .stopReason, .none:
                    break
                }
            }

            let streamSnapshot = streamAssembler.snapshot
            let currentRoundText = streamSnapshot.text
            let currentRoundThinkingContent = streamSnapshot.thinkingContent
            let currentRoundThinkingSignature = streamSnapshot.thinkingSignature
            let pendingTools = streamSnapshot.pendingTools
            let stopReason = streamSnapshot.stopReason

            // 结束流式处理监控
            streamSpan.addMetadata("deltas", value: deltaCount)
            streamSpan.addMetadata("textBytes", value: currentRoundText.count)
            streamSpan.end()

            // Persist this round's text
            if !currentRoundText.isEmpty {
                if !accumulatedText.isEmpty { accumulatedText += "\n\n" }
                accumulatedText += currentRoundText

                // 确保最后一次更新 round.text（无论是否达到阈值）
                await emitHook(
                    .didReceiveTextDelta,
                    metadata: [
                        "length": accumulatedText.count,
                        "agentRound": round,
                        "forceProjection": true
                    ],
                    projectedText: accumulatedText,
                    currentRoundText: currentRoundText
                )
            }

            if !currentRoundThinkingContent.isEmpty {
                await emitHook(
                    .didReceiveThinkingDelta,
                    metadata: [
                        "agentRound": round,
                        "forceProjection": true
                    ],
                    currentRoundThinking: currentRoundThinkingContent
                )
            }

            // Build assistant content objects for this round (for next API call)
            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []

            // Include thinking blocks from this round (required for multi-turn)
            if useThinking && !currentRoundThinkingContent.isEmpty,
               let sig = currentRoundThinkingSignature {
                assistantObjects.append(.thinking(currentRoundThinkingContent, sig))
            }
            // Persist stop reason on this round
            round.stopReason = stopReason
            try? modelContext.save()

            // Drive state machine transition based on stop_reason
            loopCtx.transition(stopReason: stopReason)
            await emitHook(
                .didResolveStopReason,
                metadata: [
                    "stopReason": stopReason ?? "nil",
                    "phase": loopCtx.phase.label,
                    "roundIndex": roundIdx
                ]
            )

            switch loopCtx.phase {

            case .executing:
                break

            case .awaitingToolResults:
                // Execute all pending tools and feed results back
                guard !pendingTools.isEmpty else {
                    // tool_use stop reason but no tools parsed — treat as error
                    loopCtx.phase = .failed
                    loopCtx.terminationReason = "stop_reason=tool_use but no tool blocks parsed"
                    break
                }
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in pendingTools {
                    let input = pending.parsedInput
                    let willExecuteHooks = await dispatchHooks(
                        .willExecuteTool,
                        metadata: [
                            "toolName": pending.name,
                            "inputLength": pending.partialJson.count,
                            "roundIndex": roundIdx,
                            "toolUseID": pending.id,
                            "agentRound": round
                        ],
                        toolName: pending.name,
                        toolInput: input
                    )
                    let toolSpan = perfLog.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)

                    assistantObjects.append(.toolUse(pending.id, pending.name, input))
                    let record = willExecuteHooks.toolCallRecord ?? makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: input,
                        message: parentMessage,
                        agentRound: round,
                        executionContext: toolExecutionContext
                    )
                    let executionOutcome = await toolExecutionCoordinator.execute(
                        pendingTool: pending,
                        record: record,
                        interceptor: toolInterceptor
                    )
                    let result = executionOutcome.result
                    if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
                        executionEvidence.insert(evidence)
                        sessionExecutionEvidence[sessionId] = executionEvidence
                    }
                    await emitHook(
                        .didExecuteTool,
                        metadata: [
                            "toolName": pending.name,
                            "status": result.toolCallStatus.rawValue,
                            "isError": result.isError,
                            "outputLength": result.text.count,
                            "roundIndex": roundIdx,
                            "toolStatus": result.toolCallStatus,
                            "toolResultSummary": result.envelope?.summary as Any,
                            "toolResultPreview": result.envelope?.preview ?? result.rawOutputText ?? result.text,
                            "toolPayloadRef": result.envelope?.payloadRef ?? input["payload_ref"]?.stringValue as Any,
                            "toolResultRawChars": result.envelope?.rawCharCount ?? result.rawOutputText?.count ?? result.text.count,
                            "toolResultInjectedChars": result.envelope?.injectedCharCount ?? result.text.count,
                            "toolResultInjectionMode": result.envelope?.injectionMode.rawValue as Any,
                            "toolPayloadLastReadRange": payloadReadRangeSummary(from: input) as Any
                        ],
                        toolName: pending.name,
                        toolInput: input,
                        toolResultText: result.text,
                        toolCallRecord: record
                    )

                    let classification = await dispatchHooks(
                        .classifyFailureTrigger,
                        metadata: ["isError": result.isError],
                        toolName: pending.name,
                        toolInput: input,
                        toolResultText: result.text,
                        toolCallRecord: record
                    )
                    if let failureTrigger = classification.failureTrigger {
                        loopCtx.pendingFailureTrigger = failureTrigger
                    }

                    toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
                    toolResultObjects.append(contentsOf: result.mediaContent)

                    // 结束工具执行监控
                    toolSpan.addMetadata("isError", value: result.isError)
                    toolSpan.addMetadata("outputLength", value: result.text.count)
                    toolSpan.end()
                }

                messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                messages.append(.init(role: .user, content: .list(toolResultObjects)))
                loopCtx.toolResultsAppended()

            case .continuingTruncatedResponse:
                // Model hit token limit; inject a continuation turn without replanning
                await emitHook(
                    .prepareContinuation,
                    metadata: [
                        "reason": "max_tokens",
                        "roundIndex": roundIdx
                    ]
                )
                _ = AgentLoopPhaseOutcomeApplier.apply(
                    phase: .continuingTruncatedResponse,
                    loopContext: &loopCtx,
                    messages: &messages,
                    accumulatedText: accumulatedText,
                    accumulatedTextBeforeRound: accumulatedTextBeforeRound,
                    currentRoundText: currentRoundText,
                    assistantObjects: assistantObjects
                )

            case .resumingAfterPause:
                // Server-side sampling pause; resume by feeding partial response back
                await emitHook(
                    .prepareResumeAfterPause,
                    metadata: [
                        "reason": "pause_turn",
                        "roundIndex": roundIdx
                    ]
                )
                _ = AgentLoopPhaseOutcomeApplier.apply(
                    phase: .resumingAfterPause,
                    loopContext: &loopCtx,
                    messages: &messages,
                    accumulatedText: accumulatedText,
                    accumulatedTextBeforeRound: accumulatedTextBeforeRound,
                    currentRoundText: currentRoundText,
                    assistantObjects: assistantObjects
                )

            case .finalizing:
                let guardHooks = await dispatchHooks(
                    .decideFinalization,
                    metadata: [
                        "executionRequirement": executionRequirement,
                        "executionEvidenceKinds": executionEvidence,
                        "retryCount": executionGuardRetryCount
                    ]
                )
                let finalizationDecision = guardHooks.decisions.compactMap { decision -> FinalizationDecision? in
                    guard case .finalization(let finalizationDecision) = decision else {
                        return nil
                    }
                    return finalizationDecision
                }.first ?? .allow

                let phaseOutcome = AgentLoopPhaseOutcomeApplier.apply(
                    phase: .finalizing,
                    finalizationDecision: finalizationDecision,
                    loopContext: &loopCtx,
                    messages: &messages,
                    accumulatedText: accumulatedText,
                    accumulatedTextBeforeRound: accumulatedTextBeforeRound,
                    currentRoundText: currentRoundText,
                    assistantObjects: assistantObjects,
                    reflectionEnabled: settings.enableReflection
                )

                if let projectedTextReset = phaseOutcome.projectedTextReset {
                    accumulatedText = projectedTextReset
                    await emitHook(
                        .didReceiveTextDelta,
                        metadata: ["length": accumulatedText.count],
                        projectedText: accumulatedText
                    )
                }

                if case .retry = finalizationDecision {
                    executionGuardRetryCount += 1
                }
                // else: shouldContinue becomes false, loop exits naturally

            case .failed:
                break

            case .idle, .cancelled, .reflecting:
                break
            }

            // 结束这一轮的性能监控
            roundSpan.addMetadata("stopReason", value: stopReason ?? "nil")
            roundSpan.addMetadata("phase", value: loopCtx.phase.label)
            roundSpan.addMetadata("textBytes", value: currentRoundText.count)
            roundSpan.end()
        }

        if loopCtx.roundIndex >= maxRounds && loopCtx.shouldContinue {
            let notice = "\n\n[Stopped: maximum rounds reached]"
            accumulatedText += notice
            parentMessage?.textContent = (parentMessage?.textContent ?? "") + notice
            await emitHook(.didFailRun, metadata: ["terminationReason": "maxRounds"])
            return AgentLoopRunResult(
                text: accumulatedText,
                completedSuccessfully: false,
                terminationReason: "maxRounds"
            )
        }

        let result = AgentLoopRunResult(
            text: accumulatedText,
            completedSuccessfully: loopCtx.phase == .finalizing,
            terminationReason: loopCtx.phase == .finalizing ? nil : loopCtx.terminationReason
        )
        await emitHook(
            result.completedSuccessfully ? .didFinishRun : .didFailRun,
            metadata: ["terminationReason": result.terminationReason ?? "completed"]
        )
        return result
    }

    private func buildStoryMemoryBootstrap(
        settings: AppSettings,
        sessionId: String,
        messages: [MessageParameter.Message],
        modelContext: ModelContext
    ) throws -> String? {
        guard settings.enableStoryMemory, !sessionId.isEmpty else { return nil }

        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.sessionId == sessionId })
        guard let session = try modelContext.fetch(descriptor).first,
              !session.activeWritingProjectId.isEmpty else {
            return nil
        }

        let currentRequest = messages.reversed()
            .first(where: { $0.role == "user" })
            .map { extractText(from: $0.content) } ?? ""

        let delegationService = StoryMemoryDelegationService(modelContext: modelContext)
        let taskType = delegationService.classifyTask(userRequest: currentRequest)
        guard taskType != .resolveProjectBinding else {
            return nil
        }

        let assembler = StoryMemoryPromptAssembler(
            modelContext: modelContext,
            retrievalService: StoryMemoryRetrievalService(modelContext: modelContext)
        )
        return try assembler.buildWritingSlice(settings: settings, session: session, currentRequest: currentRequest)
    }

    @MainActor
    private func buildUnifiedMemoryBootstrap(
        settings: AppSettings,
        session: Session?,
        sessionId: String,
        messages: [MessageParameter.Message],
        modelContext: ModelContext
    ) async throws -> MemoryRuntimeContext? {
        guard !sessionId.isEmpty else { return nil }

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

        let projectId = resolvedSession?.activeWritingProjectId
        let taskKind: MemoryTaskKind = {
            if settings.enableStoryMemory, let projectId, !projectId.isEmpty {
                return .creativeWriting
            }
            return .coding
        }()

        let workspaceRoot: String?
        if let sessionDirectory = resolvedSession?.workingDirectory, !sessionDirectory.isEmpty {
            workspaceRoot = sessionDirectory
        } else if !settings.workingDirectory.isEmpty {
            workspaceRoot = settings.workingDirectory
        } else {
            workspaceRoot = nil
        }

        let request = MemoryRuntimeRequest(
            sessionId: sessionId,
            threadId: sessionId,
            workflowRunId: nil,
            userRequest: currentRequest,
            taskKind: taskKind,
            projectId: projectId?.isEmpty == false ? projectId : nil,
            workspaceRoot: workspaceRoot,
            contextBudget: max(settings.storyMemoryPromptBudget * 1000, 4000)
        )

        let coordinator = MemoryRuntimeCoordinator(modelContext: modelContext)
        let context = try await coordinator.prepareContext(for: request)
        return context
    }

    func populateStoryMemoryAuditFields(record: ToolCall, from agentMessage: AgentMessage) {
        guard case .structured(let json) = agentMessage.content,
              let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(StoryMemoryDelegationResponse.self, from: data) else {
            return
        }

        record.storyMemoryTaskType = response.taskType.rawValue
        record.storyMemoryStatus = response.status.rawValue
        record.storyMemoryRiskSummary = response.risks.first?.message
        record.storyMemoryFallbackNote = response.fallbackNote
    }

    private func payloadReadRangeSummary(from input: MessageResponse.Content.Input) -> String? {
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

    func makeStoryMemoryBootstrapForTests(
        settings: AppSettings,
        sessionId: String,
        messages: [MessageParameter.Message],
        modelContext: ModelContext
    ) throws -> String? {
        try buildStoryMemoryBootstrap(
            settings: settings,
            sessionId: sessionId,
            messages: messages,
            modelContext: modelContext
        )
    }

    /// Returns true if the model supports Extended Thinking (3.7 Sonnet and all later models)
    func isThinkingCapable(modelId: String) -> Bool {
        // Claude 3.7+ and all Claude 4 series support Extended Thinking
        let thinkingModels = ["claude-3-7", "claude-3.7", "claude-opus-4", "claude-sonnet-4", "claude-haiku-4"]
        return thinkingModels.contains { modelId.contains($0) }
    }

    func recordReflectionFailure(
        sessionId: String,
        trigger: FailureTrigger?,
        concerns: [String],
        suggestedFixes: [String],
        store: UnifiedMemoryFileStoreAdapter? = nil,
        timestamp: Date = Date()
    ) throws {
        guard !sessionId.isEmpty, !concerns.isEmpty || !suggestedFixes.isEmpty else {
            return
        }

        let resolvedStore = store ?? UnifiedMemoryFileStoreAdapter()

        var extracted = TaskMemory(sessionId: sessionId)
        let actionLabel = trigger?.actionLabel ?? "unknown_failure"
        let reasonSummary = concerns.prefix(3).joined(separator: "; ")
        if !reasonSummary.isEmpty {
            extracted.failedAttempts = [FailedAttempt(action: actionLabel, reason: reasonSummary)]
        }
        extracted.attemptedActions = suggestedFixes.prefix(3).map { "Reflection fix: \($0)" }

        try persistTaskMemoryExtraction(
            sessionId: sessionId,
            extracted: extracted,
            store: resolvedStore,
            timestamp: timestamp
        )
    }

}
