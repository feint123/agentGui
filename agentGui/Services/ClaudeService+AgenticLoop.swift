//
//  ClaudeService+AgenticLoop.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    private var perfLog: PerformanceMonitor.Type { PerformanceMonitor.self }

    private struct PendingThinking {
        var content: String = ""
        var signature: String?
    }

    private struct PendingToolUse {
        let id: String
        let name: String
        var partialJson: String = ""

        var parsedInput: MessageResponse.Content.Input {
            guard let data = partialJson.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = jsonObject as? [String: Any] else {
                return [:]
            }

            return dictionary.mapValues(Self.dynamicContent(from:))
        }

        private static func dynamicContent(from value: Any) -> MessageResponse.Content.DynamicContent {
            switch value {
            case let string as String:
                return .string(string)
            case let bool as Bool:
                return .bool(bool)
            case let int as Int:
                return .integer(int)
            case let double as Double:
                return .double(double)
            case let array as [Any]:
                return .array(array.map(dynamicContent(from:)))
            case let dictionary as [String: Any]:
                return .dictionary(dictionary.mapValues(dynamicContent(from:)))
            default:
                return .string(String(describing: value))
            }
        }
    }

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
                if let unifiedContext = try? await self.buildUnifiedMemoryBootstrap(
                    settings: settings,
                    session: session,
                    sessionId: sessionId,
                    messages: bootstrapMessagesSnapshot,
                    modelContext: modelContext
                ) {
                    state.memoryRuntimeProfiles = unifiedContext.profiles
                    state.memoryRuntimeLayers = Array(Set(unifiedContext.records.map { $0.layer.rawValue })).sorted()
                    state.memoryRuntimeWarnings = unifiedContext.warnings

                    if let snapshot = unifiedContext.runtimeSnapshot {
                        let snapshotStore = MemoryRuntimeSnapshotStore()
                        try? snapshotStore.save(snapshot)
                        state.memoryRuntimeSnapshotID = snapshot.id
                    }

                    guard !unifiedContext.renderedPrompt.isEmpty else {
                        return nil
                    }

                    return AgentLoopMessagePatch(
                        insertions: [
                            .init(
                                index: 0,
                                message: MessageParameter.Message(
                                    role: .user,
                                    content: .text("【统一记忆切片】以下是当前任务的统一记忆视图，请优先遵守其中的当前状态、事实、事件与风险：\n\n\(unifiedContext.renderedPrompt)")
                                )
                            ),
                            .init(
                                index: 1,
                                message: MessageParameter.Message(
                                    role: .assistant,
                                    content: .text("已加载统一记忆切片，将据此继续执行当前任务。")
                                )
                            )
                        ],
                        metadata: [
                            "source": "unified",
                            "recordCount": unifiedContext.records.count,
                            "warningCount": unifiedContext.warnings.count
                        ]
                    )
                }

                let unifiedStore = UnifiedMemoryFileStoreAdapter()
                var patch = AgentLoopMessagePatch()

                if !sessionId.isEmpty,
                   let taskMem = try? self.loadTaskMemory(sessionId: sessionId, store: unifiedStore),
                   !taskMem.isEmpty,
                   let tmText = try? self.taskMemoryPromptText(sessionId: sessionId, store: unifiedStore),
                   !tmText.isEmpty {
                    patch.insertions.append(
                        .init(
                            index: 0,
                            message: MessageParameter.Message(
                                role: .user,
                                content: .text("【任务级持久记忆】这是本任务的已知状态，请优先保留这些结构化状态：\n\n\(tmText)")
                            )
                        )
                    )
                    patch.insertions.append(
                        .init(
                            index: 1,
                            message: MessageParameter.Message(
                                role: .assistant,
                                content: .text("已加载任务级持久记忆，将在后续操作中保持这些状态。")
                            )
                        )
                    )
                    patch.metadata = [
                        "source": "task-unified",
                        "confirmedFactCount": taskMem.confirmedFacts.count,
                        "failedAttemptCount": taskMem.failedAttempts.count
                    ]
                }

                if let storySlice = try? self.buildStoryMemoryBootstrap(
                    settings: settings,
                    sessionId: sessionId,
                    messages: bootstrapMessagesSnapshot,
                    modelContext: modelContext
                ),
                   !storySlice.isEmpty {
                    let insertionIndex = patch.insertions.isEmpty ? min(bootstrapMessagesSnapshot.count, 2) : 2
                    patch.insertions.append(
                        .init(
                            index: insertionIndex,
                            message: MessageParameter.Message(
                                role: .user,
                                content: .text("【创作记忆切片】以下是当前写作任务的项目级故事记忆，请优先保持人物、事件、伏笔和风格的一致性：\n\n\(storySlice)")
                            )
                        )
                    )
                    patch.insertions.append(
                        .init(
                            index: insertionIndex + 1,
                            message: MessageParameter.Message(
                                role: .assistant,
                                content: .text("已加载创作记忆切片，将据此保持情节连续性与风格一致。")
                            )
                        )
                    )
                    if patch.metadata.isEmpty {
                        patch.metadata = [
                            "source": "story",
                            "promptLength": storySlice.count
                        ]
                    }
                }

                return patch.insertions.isEmpty ? nil : patch
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

            var currentRoundText = ""
            var currentRoundThinking = PendingThinking()
            var pendingTools: [Int: PendingToolUse] = [:]
            var currentBlockIndex: Int? = nil
            var stopReason: String? = nil
            var deltaCount = 0
            var lastDeltaLogTime = ContinuousClock.now
            var deltaLogInterval: TimeInterval = 0.5 // 每0.5秒输出一次统计

            for try await event in stream {
                // content_block_start — register new block
                if let block = event.contentBlock {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        let idx = event.index ?? pendingTools.count
                        pendingTools[idx] = PendingToolUse(id: id, name: name)
                        currentBlockIndex = idx
                    } else {
                        currentBlockIndex = nil
                    }
                }
                // content_block_delta — accumulate text / thinking / partial JSON
                if let delta = event.delta {
                    switch delta.type {
                    case "text_delta":
                        if let text = delta.text {
                            let deltaSpan = perfLog.startSpan("text_delta", category: "Stream", level: .verbose)
                            currentRoundText += text
                            deltaSpan.addMetadata("bytes", value: text.count)
                            deltaSpan.end()
                            let joined = accumulatedText.isEmpty
                                ? currentRoundText
                                : accumulatedText + "\n\n" + currentRoundText
                            await emitHook(
                                .didReceiveTextDelta,
                                metadata: [
                                    "length": joined.count,
                                    "agentRound": round
                                ],
                                projectedText: joined,
                                currentRoundText: currentRoundText
                            )

                            // 统计
                            deltaCount += 1
                            perfLog.streamStats.recordDelta(text.count, round: roundIdx)
                        }
                    case "thinking_delta":
                        if let thinking = delta.thinking {
                            currentRoundThinking.content += thinking
                            await emitHook(
                                .didReceiveThinkingDelta,
                                metadata: ["agentRound": round],
                                currentRoundThinking: currentRoundThinking.content
                            )
                        }
                    case "signature_delta":
                        if let sig = delta.signature {
                            currentRoundThinking.signature = sig
                            round.thinkingSignature = sig
                        }
                    default:
                        // legacy text delta (non-streaming thinking models)
                        if let text = delta.text {
                            currentRoundText += text
                            let joined = accumulatedText.isEmpty
                                ? currentRoundText
                                : accumulatedText + "\n\n" + currentRoundText
                            await emitHook(
                                .didReceiveTextDelta,
                                metadata: [
                                    "length": joined.count,
                                    "agentRound": round
                                ],
                                projectedText: joined,
                                currentRoundText: currentRoundText
                            )
                        }
                        if let json = delta.partialJson, let idx = currentBlockIndex {
                            pendingTools[idx]?.partialJson += json
                        }
                    }

                    if let reason = delta.stopReason {
                        stopReason = reason
                    }
                }
            }

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

            if !currentRoundThinking.content.isEmpty {
                await emitHook(
                    .didReceiveThinkingDelta,
                    metadata: [
                        "agentRound": round,
                        "forceProjection": true
                    ],
                    currentRoundThinking: currentRoundThinking.content
                )
            }

            // Build assistant content objects for this round (for next API call)
            var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []

            // Include thinking blocks from this round (required for multi-turn)
            if useThinking && !currentRoundThinking.content.isEmpty,
               let sig = currentRoundThinking.signature {
                assistantObjects.append(.thinking(currentRoundThinking.content, sig))
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
                let sorted = pendingTools.sorted { $0.key < $1.key }.map { $0.value }
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []

                for pending in sorted {
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

                    let result: ToolExecutionResult
                    if let interceptor = toolInterceptor,
                       let intercepted = await interceptor(pending.name, input) {
                        result = intercepted
                    } else if pending.name == "run_subagent" {
                        let agentMsg = await executeRunSubagentTool(
                            input: input,
                            toolCallRecord: record,
                            service: service,
                            modelId: modelId,
                            settings: settings,
                            sessionId: sessionId,
                            modelContext: modelContext
                        )
                        result = agentMsg.toExecutionResult()
                        record.subagentResultKind = agentMsg.content.kindLabel
                        if !agentMsg.metadata.isEmpty {
                            record.subagentMessageMetadata = agentMsg.metadata
                        }
                        if record.subagentAgentName == "creative_memory_manager" {
                            populateStoryMemoryAuditFields(record: record, from: agentMsg)
                        }
                    } else if pending.name == "start_workflow" {
                        result = await executeStartWorkflowTool(
                            input: input,
                            modelContext: modelContext
                        )
                    } else {
                        // For bash commands (non-background), start a polling task that
                        // streams outputBuffer into record.terminalOutput every 100ms so
                        // the UI can show live output while the command is running.
                        let isBash = pending.name == "bash"
                        let bashRequest = isBash ? (try? normalizeBashToolRequest(input: input)) : nil
                        let isBackground = bashRequest?.executionMode == .background
                        let isRestart = bashRequest?.restart == true
                        var pollTask: Task<Void, Never>? = nil
                        if let bashRequest, isBash, !isBackground && !isRestart {
                            let wd = settings.workingDirectory.isEmpty ? nil : settings.workingDirectory
                            let bashSess = getBashSession(
                                for: sessionId,
                                workingDirectory: wd,
                                environmentOverrides: settings.proxyConfiguration.bashEnvironmentOverrides
                            )
                            let registry = getBashTaskRegistry(for: sessionId)
                            let taskId = record.terminalTaskId ?? bashRequest.taskId ?? pending.id
                            var snapshot = TerminalTaskSnapshot(
                                id: taskId,
                                sessionId: sessionId,
                                command: bashRequest.command ?? record.title ?? "bash",
                                executionMode: bashRequest.executionMode,
                                status: .runningForeground,
                                startedAt: record.startTime
                            )
                            await registry.upsert(snapshot)
                            pollTask = Task { @MainActor in
                                var idleDuration: TimeInterval = 0
                                while !Task.isCancelled {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                    if Task.isCancelled { break }
                                    let liveOutput = await bashSess.currentOutput()
                                    let delta = await bashSess.currentOutputDelta()
                                    if !liveOutput.isEmpty {
                                        record.terminalOutput = liveOutput
                                    }

                                    idleDuration = delta.isEmpty ? (idleDuration + 0.1) : 0
                                    let promptDecision = BashPromptAnalyzer().analyze(output: liveOutput)
                                    let observation = TerminalTaskObservation(
                                        appendedOutput: delta,
                                        processIsAlive: await bashSess.isProcessAlive(),
                                        idleDuration: idleDuration,
                                        promptDecision: promptDecision,
                                        didBackgroundLaunch: false,
                                        didTimeout: false,
                                        exitCode: nil
                                    )
                                    let update = BashTaskEventReducer().reduce(previous: snapshot, observation: observation)
                                    snapshot = update.snapshot
                                    await registry.upsert(update.snapshot)
                                    for event in update.events {
                                        await registry.appendEvent(event)
                                    }
                                    record.terminalTaskId = snapshot.id
                                    record.terminalTaskStatus = snapshot.status.rawValue
                                    record.terminalExecutionMode = snapshot.executionMode.rawValue
                                    record.terminalPromptSummary = snapshot.prompt?.promptText ?? snapshot.latestOutputSnippet
                                    if let data = try? JSONEncoder().encode(update.events),
                                       let json = String(data: data, encoding: .utf8),
                                       !json.isEmpty {
                                        record.terminalAgentActionsJSON = json
                                    }
                                }
                            }
                        }
                        result = await executeTool(
                            name: pending.name,
                            input: input,
                            settings: settings,
                            sessionId: sessionId,
                            modelContext: modelContext
                        )
                        pollTask?.cancel()
                        if let bashRequest, isBash, !isRestart {
                            let registry = getBashTaskRegistry(for: sessionId)
                            let taskId = record.terminalTaskId ?? bashRequest.taskId ?? pending.id
                            if var finalSnapshot = await registry.snapshot(taskId: taskId) {
                                if bashRequest.executionMode == .background && result.status == .success {
                                    finalSnapshot.status = .runningBackground
                                } else if result.toolCallStatus == .failed {
                                    finalSnapshot.status = .failed
                                    finalSnapshot.endedAt = Date()
                                } else if !(finalSnapshot.status == .waitingForPrompt || finalSnapshot.status == .needsUserDecision) {
                                    finalSnapshot.status = .completed
                                    finalSnapshot.endedAt = Date()
                                }
                                finalSnapshot.latestOutputSnippet = result.text
                                await registry.upsert(finalSnapshot)
                                record.terminalTaskId = finalSnapshot.id
                                record.terminalTaskStatus = finalSnapshot.status.rawValue
                                record.terminalExecutionMode = finalSnapshot.executionMode.rawValue
                                record.terminalPromptSummary = finalSnapshot.prompt?.promptText ?? firstTerminalSummaryLine(from: result.text)
                            }
                        }
                    }
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
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                messages.append(.init(
                    role: .user,
                    content: .text("Please continue your previous response exactly where you left off. Do not repeat what you already wrote and do not re-plan — just continue.")
                ))
                loopCtx.continuationInjected()

            case .resumingAfterPause:
                // Server-side sampling pause; resume by feeding partial response back
                await emitHook(
                    .prepareResumeAfterPause,
                    metadata: [
                        "reason": "pause_turn",
                        "roundIndex": roundIdx
                    ]
                )
                if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                if !assistantObjects.isEmpty {
                    messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                }
                messages.append(.init(role: .user, content: .text("Continue.")))
                loopCtx.continuationInjected()

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

                switch finalizationDecision {
                case .allow:
                    break
                case .retry(let prompt):
                    accumulatedText = accumulatedTextBeforeRound
                    await emitHook(
                        .didReceiveTextDelta,
                        metadata: ["length": accumulatedText.count],
                        projectedText: accumulatedText
                    )
                    if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                    if !assistantObjects.isEmpty {
                        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                    }
                    messages.append(.init(role: .user, content: .text(prompt ?? ExecutionGuard.correctionPrompt)))
                    executionGuardRetryCount += 1
                    loopCtx.retryAfterExecutionGuard()
                    break
                case .fail(let reason):
                    loopCtx.phase = .failed
                    loopCtx.terminationReason = reason
                    break
                }

                // Failure-driven reflection: only trigger when a specific failure event was detected
                // (tool error, reviewer rejection, or executor validation failure). Generic
                // end_turns without failures skip reflection entirely.
                if loopCtx.phase == .finalizing,
                   settings.enableReflection,
                   loopCtx.pendingFailureTrigger != nil,
                   loopCtx.reflectionCount < 3 {
                    loopCtx.phase = .reflecting
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

    private func populateStoryMemoryAuditFields(record: ToolCall, from agentMessage: AgentMessage) {
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

    // MARK: - Helpers

    private func firstTerminalSummaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
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
