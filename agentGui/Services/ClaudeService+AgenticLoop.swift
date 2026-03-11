//
//  ClaudeService+AgenticLoop.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Pending Tool Use

struct PendingToolUse {
    let id: String
    let name: String
    var partialJson: String = ""

    var parsedInput: MessageResponse.Content.Input {
        guard let data = partialJson.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: MessageResponse.Content.DynamicContent].self, from: data)) ?? [:]
    }
}

// MARK: - Pending Thinking Block

struct PendingThinking {
    var content: String = ""
    var signature: String? = nil
}

// MARK: - Agentic Loop

// MARK: - Performance Monitor Extensions

private let perfLog = PerformanceMonitor.self

extension ClaudeService {

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

    // MARK: Public Entry Point

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
            onTextAccumulated: { text in
                // 测量 UI 更新延迟
                let uiSpan = perfLog.startSpan("onTextAccumulated", category: "UI", level: .verbose)
                assistantMessage.textContent = text
                uiSpan.addMetadata("length", value: text.count)
                uiSpan.end()
            },
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
    /// - `onTextAccumulated`: called each text delta with the full accumulated text,
    ///   driving real-time UI for the main agent; sub-agents pass `{ _ in }`.
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
        onTextAccumulated: (String) -> Void,
        toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)? = nil,
        executionRequirement: ExecutionRequirement = .none
    ) async throws -> AgentLoopRunResult {
        var accumulatedText = ""
        var loopCtx = AgentLoopContext(phase: .executing)
        var loopMemory = ContextMemory()
        var lastRound: AgentRound? = nil
        let runID = UUID().uuidString
        var executionEvidence: Set<ExecutionEvidenceKind> = []
        var executionGuardRetryCount = 0
        var memoryRuntimeProfiles: [String] = []
        var memoryRuntimeLayers: [String] = []
        var memoryRuntimeWarnings: [String] = []
        var memoryRuntimeSnapshotID: String?

        func emitBusinessEvent(_ event: AgentBusinessEvent, metadata: [String: Any] = [:]) {
            let context = BusinessLogContext(
                runID: runID,
                sessionID: sessionId.isEmpty ? nil : sessionId,
                roundIndex: loopCtx.roundIndex,
                phase: loopCtx.phase.label
            )
            BusinessMonitor.emit(event, context: context, metadata: metadata, sink: businessLogSink)
        }

        emitBusinessEvent(
            .loopStarted,
            metadata: [
                "modelId": modelId,
                "maxRounds": maxRounds,
                "messageCount": messages.count
            ]
        )

        if let unifiedContext = try? await buildUnifiedMemoryBootstrap(
            settings: settings,
            session: session,
            sessionId: sessionId,
            messages: messages,
            modelContext: modelContext
        ) {
            memoryRuntimeProfiles = unifiedContext.profiles
            memoryRuntimeLayers = Array(Set(unifiedContext.records.map { $0.layer.rawValue })).sorted()
            memoryRuntimeWarnings = unifiedContext.warnings

            if let snapshot = unifiedContext.runtimeSnapshot {
                let snapshotStore = MemoryRuntimeSnapshotStore()
                try? snapshotStore.save(snapshot)
                memoryRuntimeSnapshotID = snapshot.id
            }

            if !unifiedContext.renderedPrompt.isEmpty {
                emitBusinessEvent(
                    .memoryBootstrapLoaded,
                    metadata: [
                        "source": "unified",
                        "recordCount": unifiedContext.records.count,
                        "warningCount": unifiedContext.warnings.count
                    ]
                )
                messages.insert(
                    MessageParameter.Message(role: .user, content: .text("【统一记忆切片】以下是当前任务的统一记忆视图，请优先遵守其中的当前状态、事实、事件与风险：\n\n\(unifiedContext.renderedPrompt)")),
                    at: 0
                )
                messages.insert(
                    MessageParameter.Message(role: .assistant, content: .text("已加载统一记忆切片，将据此继续执行当前任务。")),
                    at: 1
                )
            }
        } else {
            let unifiedStore = UnifiedMemoryFileStoreAdapter()

            if !sessionId.isEmpty,
               let taskMem = try? loadTaskMemory(sessionId: sessionId, store: unifiedStore),
               !taskMem.isEmpty,
               let tmText = try? taskMemoryPromptText(sessionId: sessionId, store: unifiedStore),
               !tmText.isEmpty {
                emitBusinessEvent(
                    .memoryBootstrapLoaded,
                    metadata: [
                        "source": "task-unified",
                        "confirmedFactCount": taskMem.confirmedFacts.count,
                        "failedAttemptCount": taskMem.failedAttempts.count
                    ]
                )
                messages.insert(
                    MessageParameter.Message(role: .user, content: .text("【任务级持久记忆】这是本任务的已知状态，请优先保留这些结构化状态：\n\n\(tmText)")),
                    at: 0
                )
                messages.insert(
                    MessageParameter.Message(role: .assistant, content: .text("已加载任务级持久记忆，将在后续操作中保持这些状态。")),
                    at: 1
                )
            }

            if let storySlice = try? buildStoryMemoryBootstrap(
                settings: settings,
                sessionId: sessionId,
                messages: messages,
                modelContext: modelContext
            ),
                  !storySlice.isEmpty {
                emitBusinessEvent(
                    .memoryBootstrapLoaded,
                    metadata: [
                        "source": "story",
                        "promptLength": storySlice.count
                    ]
                )
                let insertionIndex = min(messages.count, 2)
                messages.insert(
                    MessageParameter.Message(role: .user, content: .text("【创作记忆切片】以下是当前写作任务的项目级故事记忆，请优先保持人物、事件、伏笔和风格的一致性：\n\n\(storySlice)")),
                    at: insertionIndex
                )
                messages.insert(
                    MessageParameter.Message(role: .assistant, content: .text("已加载创作记忆切片，将据此保持情节连续性与风格一致。")),
                    at: insertionIndex + 1
                )
            }
        }
        while loopCtx.shouldContinue && loopCtx.roundIndex < maxRounds {
            try Task.checkCancellation()

            // Reflection phase runs without a new streaming API call.
            // It must be handled here, before the streaming block, so that
            // loopCtx.transition(stopReason:) cannot overwrite the phase.
            if loopCtx.phase == .reflecting {
                let trigger = loopCtx.pendingFailureTrigger
                emitBusinessEvent(
                    .reflectionStarted,
                    metadata: [
                        "reflectionPass": loopCtx.reflectionCount + 1,
                        "trigger": trigger?.description ?? "none"
                    ]
                )
                let reflection = await reflectOnRound(
                    messages: messages,
                    service: service,
                    modelId: modelId,
                    settings: settings,
                    failureTrigger: trigger
                )
                // Consume the failure trigger regardless of reflection outcome
                loopCtx.pendingFailureTrigger = nil

                // Persist on the most-recent round (already created by the previous iteration)
                if let ref = reflection {
                    // Stamp the reflection data onto the last completed round
                    if let round = lastRound {
                        round.reflectionConfidence = ref.confidence
                        round.reflectionConcerns = ref.concerns
                        round.reflectionSuggestedFixes = ref.suggestedFixes
                        round.reflectionShouldRetry = ref.shouldRetry
                        try? modelContext.save()
                    }

                    // Write failure + diagnosis to unified task memory so subsequent rounds (and
                    // future sessions) can avoid repeating the same mistake.
                    if (!ref.concerns.isEmpty || !ref.suggestedFixes.isEmpty), !sessionId.isEmpty {
                        do {
                            try recordReflectionFailure(
                                sessionId: sessionId,
                                trigger: trigger,
                                concerns: ref.concerns,
                                suggestedFixes: ref.suggestedFixes
                            )
                        } catch {
                            emitBusinessEvent(
                                .reflectionCompleted,
                                metadata: [
                                    "confidence": ref.confidence,
                                    "shouldRetry": ref.shouldRetry,
                                    "concernCount": ref.concerns.count,
                                    "suggestedFixCount": ref.suggestedFixes.count,
                                    "taskMemoryWriteStatus": "failed",
                                    "taskMemoryWriteError": String(describing: error)
                                ]
                            )
                        }
                    }

                    // Inject a targeted correction turn only when a retry is warranted
                    if ref.shouldRetry && !ref.suggestedFixes.isEmpty {
                        let triggerContext = trigger.map { "Triggered by: \($0.description)\n\n" } ?? ""
                        let fixList = ref.suggestedFixes
                            .enumerated()
                            .map { "\($0.offset + 1). \($0.element)" }
                            .joined(separator: "\n")
                        let correctionPrompt = """
                            \(triggerContext)A failure was detected and analysed. \
                            Please address the following corrections before retrying:\n\(fixList)
                            """
                        messages.append(.init(role: .user, content: .text(correctionPrompt)))
                    }
                        emitBusinessEvent(
                            .reflectionCompleted,
                            metadata: [
                                "confidence": ref.confidence,
                                "shouldRetry": ref.shouldRetry,
                                "concernCount": ref.concerns.count,
                                "suggestedFixCount": ref.suggestedFixes.count,
                                "taskMemoryWriteStatus": sessionId.isEmpty ? "skipped" : "completed"
                            ]
                        )
                    loopCtx.reflectionComplete(shouldRetry: ref.shouldRetry)
                } else {
                        emitBusinessEvent(
                            .reflectionCompleted,
                            metadata: [
                                "result": "missing",
                                "shouldRetry": false
                            ]
                        )
                    loopCtx.reflectionComplete(shouldRetry: false)
                }
                continue
            }

            emitBusinessEvent(
                .roundStarted,
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
            lastRound = round
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

            // UI 更新节流：每累积约 500 个字符才更新一次
            var lastUpdateLength = 0
            let uiUpdateThreshold = 50 // 字符阈值

            // Thinking 更新节流：每累积约 500 个字符才更新一次
            var lastThinkingUpdateLength = 0
            let thinkingUpdateThreshold = 200 // thinking 字符阈值

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

                            // 节流 round.text 更新：只在文本增长达到阈值时才更新 SwiftData
                            // 这会触发 SwiftUI 重新计算 agentAnswerText
                            let currentLength = currentRoundText.count
                            if currentLength - lastUpdateLength >= uiUpdateThreshold {
                                round.text = currentRoundText
                                lastUpdateLength = currentLength
                                // 同时更新 UI（保持一致性）
                                let joined = accumulatedText.isEmpty
                                    ? currentRoundText
                                    : accumulatedText + "\n\n" + currentRoundText
                                onTextAccumulated(joined)
                            }

                            // 统计
                            deltaCount += 1
                            perfLog.streamStats.recordDelta(text.count, round: roundIdx)
                        }
                    case "thinking_delta":
                        if let thinking = delta.thinking {
                            currentRoundThinking.content += thinking

                            // 节流 round.thinkingContent 更新
                            let currentThinkingLength = currentRoundThinking.content.count
                            if currentThinkingLength - lastThinkingUpdateLength >= thinkingUpdateThreshold {
                                round.thinkingContent = currentRoundThinking.content
                                lastThinkingUpdateLength = currentThinkingLength
                            }
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

                            // 节流 round.text 更新
                            let currentLength = currentRoundText.count
                            if currentLength - lastUpdateLength >= uiUpdateThreshold {
                                round.text = currentRoundText
                                lastUpdateLength = currentLength
                                let joined = accumulatedText.isEmpty
                                    ? currentRoundText
                                    : accumulatedText + "\n\n" + currentRoundText
                                onTextAccumulated(joined)
                            }
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
                // 这是必须的，否则最后不足阈值的内容不会显示
                round.text = currentRoundText

                // 确保 UI 也更新到最终状态
                onTextAccumulated(accumulatedText)
            }

            // 确保最后一次更新 thinkingContent（无论是否达到阈值）
            if !currentRoundThinking.content.isEmpty {
                round.thinkingContent = currentRoundThinking.content
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
            emitBusinessEvent(
                .stopReasonReceived,
                metadata: [
                    "stopReason": stopReason ?? "nil",
                    "phase": loopCtx.phase.label,
                    "roundIndex": roundIdx
                ]
            )

            switch loopCtx.phase {

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
                    emitBusinessEvent(
                        .toolExecutionStarted,
                        metadata: [
                            "toolName": pending.name,
                            "inputLength": pending.partialJson.count,
                            "roundIndex": roundIdx
                        ]
                    )
                    let toolSpan = perfLog.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)

                    let input = pending.parsedInput
                    assistantObjects.append(.toolUse(pending.id, pending.name, input))

                    let record = makeToolCallRecord(
                        toolUseId: pending.id,
                        toolName: pending.name,
                        input: input,
                        message: parentMessage,
                        agentRound: round
                    )
                    if !memoryRuntimeProfiles.isEmpty {
                        record.memoryRuntimeProfiles = memoryRuntimeProfiles
                    }
                    if !memoryRuntimeLayers.isEmpty {
                        record.memoryRuntimeLayers = memoryRuntimeLayers
                    }
                    if !memoryRuntimeWarnings.isEmpty {
                        record.memoryRuntimeWarnings = memoryRuntimeWarnings
                    }
                    if let memoryRuntimeSnapshotID, !memoryRuntimeSnapshotID.isEmpty {
                        record.memoryRuntimeSnapshotID = memoryRuntimeSnapshotID
                    }
                    modelContext.insert(record)
                    try? modelContext.save()

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
                    record.terminalOutput = result.text
                    record.status = result.toolCallStatus
                    record.endTime = Date()
                    if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
                        executionEvidence.insert(evidence)
                        sessionExecutionEvidence[sessionId] = executionEvidence
                    }
                    try? modelContext.save()

                    // Detect failure events that warrant failure-driven reflection.
                    // Tool error takes priority; for subagents, inspect the result text for
                    // reviewer rejection or executor validation failure signals.
                    if result.isError {
                        loopCtx.pendingFailureTrigger = .toolFailure(
                            toolName: pending.name,
                            errorText: result.text
                        )
                    } else if pending.name == "run_subagent" {
                        let agentName = input["agent_name"]?.stringValue ?? ""
                        if agentName == "reviewer" && result.text.contains("needs_revision") {
                            loopCtx.pendingFailureTrigger = .reviewerRejection(feedback: result.text)
                        } else if agentName == "executor" &&
                                  (result.text.contains("\"status\": \"failed\"") ||
                                   result.text.contains("\"status\":\"failed\"")) {
                            loopCtx.pendingFailureTrigger = .executorValidationFailure(detail: result.text)
                        }
                    }

                    emitBusinessEvent(
                        .toolExecutionFinished,
                        metadata: [
                            "toolName": pending.name,
                            "status": result.toolCallStatus.rawValue,
                            "isError": result.isError,
                            "outputLength": result.text.count,
                            "roundIndex": roundIdx
                        ]
                    )

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
                emitBusinessEvent(
                    .continuationInjected,
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
                emitBusinessEvent(
                    .continuationInjected,
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
                let guardDecision = ExecutionGuard.resolveFinalization(
                    requirement: executionRequirement,
                    evidenceKinds: executionEvidence,
                    retryCount: executionGuardRetryCount
                )
                switch guardDecision {
                case .allow:
                    break
                case .requestExecution(let prompt):
                    accumulatedText = accumulatedTextBeforeRound
                    onTextAccumulated(accumulatedText)
                    if !currentRoundText.isEmpty { assistantObjects.append(.text(currentRoundText)) }
                    if !assistantObjects.isEmpty {
                        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
                    }
                    messages.append(.init(role: .user, content: .text(prompt)))
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
                let reason = loopCtx.terminationReason ?? "stop_reason=\(stopReason ?? "nil")"
                let errorNote = "\n\n⚠️ Agent loop ended unexpectedly (\(reason))."
                accumulatedText += errorNote
                parentMessage?.textContent = (parentMessage?.textContent ?? "") + errorNote

            default:
                break
            }

            // 结束这一轮的性能监控
            roundSpan.end()
        }

        // Safety: loop exited because maxRounds was reached (not a natural stop)
        if loopCtx.roundIndex >= maxRounds && loopCtx.shouldContinue {
            let notice = "\n\n⚠️ Agent loop stopped after reaching the maximum of \(maxRounds) rounds."
            accumulatedText += notice
            parentMessage?.textContent = (parentMessage?.textContent ?? "") + notice
            emitBusinessEvent(.loopFailed, metadata: ["terminationReason": "maxRounds"])
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
        emitBusinessEvent(
            result.completedSuccessfully ? .loopFinished : .loopFailed,
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
