import Foundation
import SwiftAnthropic
import SwiftData

/// executeStreamingRound 的纯产物。
/// 它把 stream 消费和 phase outcome 应用解耦，避免后者继续依赖一长串局部变量。
struct RoundOutcome {
    let roundIndex: Int
    let round: AgentRound
    let currentRoundText: String
    let currentRoundThinking: String
    let pendingTools: [AgentLoopPendingTool]
    let stopReason: String?
    let assistantObjects: [MessageParameter.Message.Content.ContentObject]
    let accumulatedTextBeforeRound: String
}

@MainActor
/// 承载单轮和单阶段执行逻辑。
/// Runner 只保留状态机骨架；具体的 round 消费、tool result 注入、finalization 决策都在这里完成。
struct AgentLoopRoundExecutor {
    let claudeService: ClaudeService
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let sharedState: AgentLoopSharedStateAccess
    let emitter: AgentLoopHookEmitter
    let toolCoordinator: AgentLoopToolExecutionCoordinator

    func applyBootstrap(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws {
        // bootstrap patch 只负责前置插入消息，不在这里决定 run 的开始/结束事件。
        guard let bootstrapResult = try? await emitter.dispatch(
            .prepareRun,
            state: state,
            messages: messages
        ),
        let patch = bootstrapResult.messagePatch,
        !patch.insertions.isEmpty else {
            return
        }

        for insertion in patch.insertions.sorted(by: { $0.index < $1.index }) {
            messages.insert(insertion.message, at: min(insertion.index, messages.count))
        }
        if !patch.metadata.isEmpty {
            await emitter.emit(
                .didApplyBootstrap,
                state: state,
                messages: messages,
                overrides: .init(metadata: patch.metadata)
            )
        }
    }

    func executeReflection(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async {
        // 进入 reflecting 时不会发起新的主模型请求，而是消费上一轮留下的 failure trigger。
        let trigger = state.loopCtx.pendingFailureTrigger
        await emitter.emit(
            .willStartReflection,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "reflectionPass": state.loopCtx.reflectionCount + 1,
                "trigger": trigger?.description ?? "none"
            ])
        )
        let reflectionHooks = (try? await emitter.dispatch(
            .processReflection,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "reflectionPass": state.loopCtx.reflectionCount + 1,
                "trigger": trigger?.description ?? "none"
            ])
        )) ?? AgentLoopHookDispatchResult()
        // reflection 只消费一次 trigger；无论 hook 给出何种结果，都不能把旧 trigger 带进下一轮。
        state.loopCtx.pendingFailureTrigger = nil

        if let resolution = reflectionHooks.reflectionResolution {
            if let correctionPrompt = resolution.correctionPrompt {
                messages.append(.init(role: .user, content: .text(correctionPrompt)))
            }
            await emitter.emit(
                .didCompleteReflection,
                state: state,
                messages: messages,
                overrides: .init(metadata: [
                    "shouldRetry": resolution.shouldRetry,
                    "hasCorrectionPrompt": resolution.correctionPrompt != nil
                ])
            )
            state.loopCtx.reflectionComplete(shouldRetry: resolution.shouldRetry)
            return
        }

        await emitter.emit(
            .didCompleteReflection,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "result": "missing",
                "shouldRetry": false
            ])
        )
        state.loopCtx.reflectionComplete(shouldRetry: false)
    }

    func executeVerification(
        state: inout AgentLoopRunState,
        messages: [MessageParameter.Message]
    ) async throws {
        // verification 优先读 in-memory report，再回落到持久化 store，保持和主循环之前的 gate 语义一致。
        let sessionId = runtime.sessionId
        let modelContext = runtime.modelContext
        let existingVerification = sharedState.readVerification(sessionId)
            ?? SessionTaskStateStore(modelContext: modelContext).verification(for: sessionId)
        emitter.emitBusinessEvent(
            .verificationStarted,
            state: state,
            metadata: [
                "hasVerificationRecord": existingVerification != nil,
                "executionEvidenceCount": state.executionEvidence.count,
                "answerLength": state.accumulatedText.count,
                "pendingFailureTrigger": state.loopCtx.pendingFailureTrigger?.actionLabel ?? "none"
            ]
        )
        let verificationCoordinator = AgentLoopVerificationCoordinator(
            claudeService: claudeService,
            service: request.service,
            modelId: request.modelId,
            settings: runtime.settings,
            sessionId: sessionId,
            modelContext: modelContext,
            runID: state.runID,
            roundIndex: state.loopCtx.roundIndex,
            parentMessage: runtime.parentMessage
        )
        let verificationOutcome = try await verificationCoordinator.verify(
            currentAnswer: state.accumulatedText,
            executionEvidence: state.executionEvidence,
            existingVerification: existingVerification,
            latestFailureTrigger: state.loopCtx.pendingFailureTrigger
        )
        state.verificationState = verificationOutcome.verificationState
        state.hookState.verificationState = verificationOutcome.verificationState
        sharedState.writeVerification(sessionId, verificationOutcome.report)

        if let failureTrigger = verificationOutcome.failureTrigger {
            state.loopCtx.pendingFailureTrigger = failureTrigger
        }
        let verificationObservations = [
            verificationOutcome.report.summary,
            verificationOutcome.verificationState.frontier.first?.recommendedProbe,
            verificationOutcome.verificationState.certificate?.stopReason
        ].compactMap { summary in
            let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        let verificationEvents = verificationEvents(
            for: verificationOutcome.verificationState,
            sessionId: sessionId,
            roundIndex: state.loopCtx.roundIndex,
            passed: verificationOutcome.passed
        )
        recordEpistemicInputEnvelope(
            sessionId: sessionId,
            roundIndex: state.loopCtx.roundIndex,
            messages: messages,
            toolObservations: verificationObservations,
            events: verificationEvents
        )
        state.loopCtx.verificationComplete(passed: verificationOutcome.passed)
    }

    private func verificationEvents(
        for verificationState: VerificationState,
        sessionId: String,
        roundIndex: Int,
        passed: Bool
    ) -> [AtomicEpistemicEvent] {
        let sourceRef = "verification:\(sessionId):\(roundIndex)"
        var events = [
            AtomicEpistemicEvent(
                kind: .claimResolved,
                summary: passed ? "verification passed" : "verification failed",
                sourceRefs: [sourceRef]
            )
        ]

        events.append(contentsOf: verificationState.frontier.map {
            AtomicEpistemicEvent(
                kind: .claimRaised,
                summary: $0.openQuestion,
                sourceRefs: [sourceRef]
            )
        })
        events.append(contentsOf: verificationState.repairQueue.map {
            AtomicEpistemicEvent(
                kind: .actionProposed,
                summary: $0,
                sourceRefs: [sourceRef]
            )
        })
        events.append(contentsOf: verificationState.certificate?.residualRisks.map {
            AtomicEpistemicEvent(
                kind: .observationReceived,
                summary: $0,
                sourceRefs: [sourceRef]
            )
        } ?? [])
        return events
    }

    func executeStreamingRound(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws -> RoundOutcome {
        let perfLog = PerformanceMonitor.self
        let modelId = request.modelId
        let tools = request.tools
        let system = request.system
        let sessionId = runtime.sessionId
        let modelContext = runtime.modelContext

        await emitter.emit(
            .willStartRound,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "messageCount": messages.count,
                "phase": state.loopCtx.phase.label,
                "modelId": modelId
            ])
        )
        let accumulatedTextBeforeRound = state.accumulatedText

        let roundSpan = perfLog.startSpan("Round_\(state.loopCtx.roundIndex)", category: "Loop", level: .normal)
        defer {
            roundSpan.end()
        }

        // 压缩发生在真正发起下一次模型调用之前，这样 token 统计和 stream 输入看到的是同一份 messages。
        await claudeService.compressIfNeeded(
            messages: &messages,
            memory: &state.loopMemory,
            service: request.service,
            modelId: modelId,
            sessionId: sessionId
        )

        sharedState.setCurrentModelId(modelId)
        let useThinking = runtime.settings.enableExtendedThinking && claudeService.isThinkingCapable(modelId: modelId)
        let budget = runtime.settings.extendedThinkingBudget
        let maxTokens = useThinking ? max(budget + 4096, 16000) : 8192

        let params = MessageParameter(
            model: .other(modelId),
            messages: messages,
            maxTokens: maxTokens,
            system: system,
            tools: tools.isEmpty ? nil : tools,
            thinking: useThinking ? .init(budgetTokens: budget) : nil
        )

        if let tokenCount = try? await request.service.countTokens(
            parameter: MessageTokenCountParameter(
                model: .other(modelId),
                messages: messages,
                system: system,
                tools: tools.isEmpty ? nil : tools
            )
        ) {
            sharedState.setCurrentInputTokens(tokenCount.inputTokens)
        }

        let stream = try await request.service.streamMessage(params)
        let roundIdx = state.loopCtx.nextRound()

        let streamSpan = perfLog.startSpan("StreamRound_\(roundIdx)", category: "API", level: .normal)

        let round = runtime.makeRound(roundIdx)
        state.hookState.lastRound = round
        modelContext.insert(round)
        try? modelContext.save()

        var streamAssembler = AgentLoopRoundStreamAssembler()
        var deltaCount = 0

        for try await event in stream {
            let delta = streamAssembler.consume(event)
            let snapshot = streamAssembler.snapshot

            switch delta {
            case .text(let text):
                // projectedText 需要体现“历史累计 + 当前轮已流出文本”，UI 才能在流式阶段保持连续视图。
                let joined = state.accumulatedText.isEmpty
                    ? snapshot.text
                    : state.accumulatedText + "\n\n" + snapshot.text
                await emitter.emit(
                    .didReceiveTextDelta,
                    state: state,
                    messages: messages,
                    overrides: .init(metadata: [
                        "length": joined.count,
                        "agentRound": round
                    ], projectedText: joined, currentRoundText: snapshot.text)
                )

                deltaCount += 1
                perfLog.streamStats.recordDelta(text.count, round: roundIdx)

            case .thinking:
                await emitter.emit(
                    .didReceiveThinkingDelta,
                    state: state,
                    messages: messages,
                    overrides: .init(
                        metadata: ["agentRound": round],
                        currentRoundThinking: snapshot.thinkingContent
                    )
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

        streamSpan.addMetadata("deltas", value: deltaCount)
        streamSpan.addMetadata("textBytes", value: currentRoundText.count)
        streamSpan.end()

        if !currentRoundText.isEmpty {
            if !state.accumulatedText.isEmpty { state.accumulatedText += "\n\n" }
            state.accumulatedText += currentRoundText

            // 流结束后强制再投影一次，确保 round.text 与最终 accumulatedText 同步到最新值。
            await emitter.emit(
                .didReceiveTextDelta,
                state: state,
                messages: messages,
                overrides: .init(metadata: [
                    "length": state.accumulatedText.count,
                    "agentRound": round,
                    "forceProjection": true
                ], projectedText: state.accumulatedText, currentRoundText: currentRoundText)
            )
        }

        if !currentRoundThinkingContent.isEmpty {
            await emitter.emit(
                .didReceiveThinkingDelta,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: [
                        "agentRound": round,
                        "forceProjection": true
                    ],
                    currentRoundThinking: currentRoundThinkingContent
                )
            )
        }

        var assistantObjects: [MessageParameter.Message.Content.ContentObject] = []
        if useThinking && !currentRoundThinkingContent.isEmpty,
           let sig = currentRoundThinkingSignature {
            assistantObjects.append(.thinking(currentRoundThinkingContent, sig))
        }
        round.stopReason = stopReason
        try? modelContext.save()

        state.loopCtx.transition(stopReason: stopReason)
        await emitter.emit(
            .didResolveStopReason,
            state: state,
            messages: messages,
            overrides: .init(metadata: [
                "stopReason": stopReason ?? "nil",
                "phase": state.loopCtx.phase.label,
                "roundIndex": roundIdx
            ])
        )

        roundSpan.addMetadata("stopReason", value: stopReason ?? "nil")
        roundSpan.addMetadata("phase", value: state.loopCtx.phase.label)
        roundSpan.addMetadata("textBytes", value: currentRoundText.count)

        recordEpistemicInputEnvelope(
            sessionId: sessionId,
            roundIndex: roundIdx,
            messages: messages,
            currentRoundText: currentRoundText,
            events: stopReason.map {
                [
                    AtomicEpistemicEvent(
                        kind: .observationReceived,
                        summary: "stop_reason=\($0)",
                        sourceRefs: ["round:\(roundIdx)"]
                    )
                ]
            } ?? []
        )

        return RoundOutcome(
            roundIndex: roundIdx,
            round: round,
            currentRoundText: currentRoundText,
            currentRoundThinking: currentRoundThinkingContent,
            pendingTools: pendingTools,
            stopReason: stopReason,
            assistantObjects: assistantObjects,
            accumulatedTextBeforeRound: accumulatedTextBeforeRound
        )
    }

    func applyPhaseOutcome(
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws {
        // executeStreamingRound 只负责把 stop_reason 映射成 phase；真正的副作用应用统一收敛在这里。
        switch state.loopCtx.phase {
        case .executing:
            break

        case .awaitingToolResults:
            try await applyToolResults(outcome: outcome, state: &state, messages: &messages)

        case .continuingTruncatedResponse:
            await emitter.emit(
                .prepareContinuation,
                state: state,
                messages: messages,
                overrides: .init(metadata: [
                    "reason": "max_tokens",
                    "roundIndex": outcome.roundIndex
                ])
            )
            _ = AgentLoopPhaseOutcomeApplier.apply(
                phase: .continuingTruncatedResponse,
                loopContext: &state.loopCtx,
                messages: &messages,
                accumulatedText: state.accumulatedText,
                accumulatedTextBeforeRound: outcome.accumulatedTextBeforeRound,
                currentRoundText: outcome.currentRoundText,
                assistantObjects: outcome.assistantObjects
            )

        case .resumingAfterPause:
            await emitter.emit(
                .prepareResumeAfterPause,
                state: state,
                messages: messages,
                overrides: .init(metadata: [
                    "reason": "pause_turn",
                    "roundIndex": outcome.roundIndex
                ])
            )
            _ = AgentLoopPhaseOutcomeApplier.apply(
                phase: .resumingAfterPause,
                loopContext: &state.loopCtx,
                messages: &messages,
                accumulatedText: state.accumulatedText,
                accumulatedTextBeforeRound: outcome.accumulatedTextBeforeRound,
                currentRoundText: outcome.currentRoundText,
                assistantObjects: outcome.assistantObjects
            )

        case .finalizing:
            await applyFinalization(outcome: outcome, state: &state, messages: &messages)

        case .failed:
            break

        case .idle, .cancelled, .verifying, .reflecting:
            break
        }
    }

    func buildResult(
        state: AgentLoopRunState,
        messages: [MessageParameter.Message]
    ) async -> AgentLoopRunResult {
        // maxRounds 是唯一一个在 while 退出后补终止文本的路径，因此结果组装必须统一收口在这里。
        if state.loopCtx.roundIndex >= request.maxRounds && state.loopCtx.shouldContinue {
            let notice = "\n\n[Stopped: maximum rounds reached]"
            var failedState = state
            failedState.accumulatedText += notice
            runtime.parentMessage?.textContent = (runtime.parentMessage?.textContent ?? "") + notice
            await emitter.emit(
                .didFailRun,
                state: failedState,
                messages: messages,
                overrides: .init(metadata: ["terminationReason": "maxRounds"])
            )
            return AgentLoopRunResult(
                text: failedState.accumulatedText,
                completedSuccessfully: false,
                terminationReason: "maxRounds"
            )
        }

        let result = AgentLoopRunResult(
            text: state.accumulatedText,
            completedSuccessfully: state.loopCtx.phase == .finalizing,
            terminationReason: state.loopCtx.phase == .finalizing ? nil : state.loopCtx.terminationReason
        )
        await emitter.emit(
            result.completedSuccessfully ? .didFinishRun : .didFailRun,
            state: state,
            messages: messages,
            overrides: .init(metadata: ["terminationReason": result.terminationReason ?? "completed"])
        )
        return result
    }

    private func applyToolResults(
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws {
        // tool_use 没有解析出任何 tool block 是明确失败，而不是空操作。
        guard !outcome.pendingTools.isEmpty else {
            state.loopCtx.phase = .failed
            state.loopCtx.terminationReason = "stop_reason=tool_use but no tool blocks parsed"
            return
        }

        var assistantObjects = outcome.assistantObjects
        if !outcome.currentRoundText.isEmpty {
            assistantObjects.append(.text(outcome.currentRoundText))
        }
        var toolResultObjects: [MessageParameter.Message.Content.ContentObject] = []
        var toolObservations: [String] = []

        for pending in outcome.pendingTools {
            let input = pending.parsedInput
            let willExecuteHooks = (try? await emitter.dispatch(
                .willExecuteTool,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: [
                        "toolName": pending.name,
                        "inputLength": pending.partialJson.count,
                        "roundIndex": outcome.roundIndex,
                        "toolUseID": pending.id,
                        "agentRound": outcome.round
                    ],
                    toolName: pending.name,
                    toolInput: input
                )
            )) ?? AgentLoopHookDispatchResult()
            let toolSpan = PerformanceMonitor.self.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)

            assistantObjects.append(.toolUse(pending.id, pending.name, input))
            let record = willExecuteHooks.toolCallRecord ?? claudeService.makeToolCallRecord(
                toolUseId: pending.id,
                toolName: pending.name,
                input: input,
                message: runtime.parentMessage,
                agentRound: outcome.round,
                executionContext: request.toolExecutionContext
            )
            let executionOutcome = await toolCoordinator.execute(
                pendingTool: pending,
                record: record,
                interceptor: runtime.toolInterceptor
            )
            let result = executionOutcome.result
            // execution evidence 会驱动 finalization guard，因此必须在每个 tool 完成后立即写回共享状态。
            if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
                state.executionEvidence.insert(evidence)
                sharedState.writeExecutionEvidence(runtime.sessionId, state.executionEvidence)
            }
            await emitter.emit(
                .didExecuteTool,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: [
                        "toolName": pending.name,
                        "status": result.toolCallStatus.rawValue,
                        "isError": result.isError,
                        "outputLength": result.text.count,
                        "roundIndex": outcome.roundIndex,
                        "toolStatus": result.toolCallStatus,
                        "toolResultSummary": result.envelope?.summary as Any,
                        "toolResultPreview": result.envelope?.preview ?? result.rawOutputText ?? result.text,
                        "toolPayloadRef": result.envelope?.payloadRef ?? input["payload_ref"]?.stringValue as Any,
                        "toolResultRawChars": result.envelope?.rawCharCount ?? result.rawOutputText?.count ?? result.text.count,
                        "toolResultInjectedChars": result.envelope?.injectedCharCount ?? result.text.count,
                        "toolResultInjectionMode": result.envelope?.injectionMode.rawValue as Any,
                        "toolPayloadLastReadRange": claudeService.payloadReadRangeSummary(from: input) as Any
                    ],
                    toolName: pending.name,
                    toolInput: input,
                    toolResultText: result.text,
                    toolCallRecord: record
                )
            )

            let classification = (try? await emitter.dispatch(
                .classifyFailureTrigger,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: ["isError": result.isError],
                    toolName: pending.name,
                    toolInput: input,
                    toolResultText: result.text,
                    toolCallRecord: record
                )
            )) ?? AgentLoopHookDispatchResult()
            if let failureTrigger = classification.failureTrigger {
                state.loopCtx.pendingFailureTrigger = failureTrigger
            }

            let observation = (result.rawOutputText ?? result.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !observation.isEmpty {
                toolObservations.append(observation)
            }

            toolResultObjects.append(.toolResult(pending.id, result.text, isError: result.isError ? true : nil))
            toolResultObjects.append(contentsOf: result.mediaContent)

            toolSpan.addMetadata("isError", value: result.isError)
            toolSpan.addMetadata("outputLength", value: result.text.count)
            toolSpan.end()
        }

        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
        messages.append(.init(role: .user, content: .list(toolResultObjects)))
        recordEpistemicInputEnvelope(
            sessionId: runtime.sessionId,
            roundIndex: outcome.roundIndex,
            messages: messages,
            toolObservations: toolObservations,
            events: toolObservations.map {
                AtomicEpistemicEvent(
                    kind: .observationReceived,
                    summary: $0,
                    sourceRefs: ["tool-round:\(outcome.roundIndex)"]
                )
            }
        )
        state.loopCtx.toolResultsAppended()
    }

    private func applyFinalization(
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async {
        // finalization 不增加新的 phase；这里只扩展 verifying gate 的触发条件。
        let storedVerification = SessionTaskStateStore(modelContext: runtime.modelContext).verification(for: runtime.sessionId)
        let inMemoryVerification = sharedState.readVerification(runtime.sessionId)
        let hasExecutionEvidence = !state.executionEvidence.isEmpty
        let userTaskText = primaryUserTaskText(from: messages)
        let autoVerificationAssessment: AutoVerificationAssessment?

        if request.toolExecutionContext == .mainAgent,
           inMemoryVerification == nil,
           storedVerification == nil,
           !hasExecutionEvidence,
           !userTaskText.isEmpty,
           !state.accumulatedText.isEmpty {
            autoVerificationAssessment = await claudeService.assessAutoVerificationNeed(
                userRequest: userTaskText,
                currentAnswer: state.accumulatedText,
                service: request.service,
                modelId: request.modelId
            )
        } else {
            autoVerificationAssessment = nil
        }

        let verificationEnabled = request.toolExecutionContext == .mainAgent && (
            inMemoryVerification != nil ||
            storedVerification != nil ||
            hasExecutionEvidence ||
            ExecutionGuard.shouldAutoVerify(autoVerificationAssessment)
        )

        emitter.emitBusinessEvent(
            .verificationGateEvaluated,
            state: state,
            metadata: [
                "verificationEnabled": verificationEnabled,
                "hasInMemoryVerification": inMemoryVerification != nil,
                "hasStoredVerification": storedVerification != nil,
                "hasExecutionEvidence": hasExecutionEvidence,
                "toolExecutionContext": request.toolExecutionContext.rawValue,
                "executionEvidenceCount": state.executionEvidence.count,
                "autoVerifySuggested": autoVerificationAssessment?.shouldAutoVerify as Any,
                "autoVerifyConfidence": autoVerificationAssessment?.confidence as Any,
                "autoVerifyRationale": autoVerificationAssessment?.rationale as Any
            ]
        )

        if !verificationEnabled {
            emitter.emitBusinessEvent(
                .verificationSkipped,
                state: state,
                metadata: [
                    "reason": "verification gate disabled",
                    "hasInMemoryVerification": inMemoryVerification != nil,
                    "hasStoredVerification": storedVerification != nil,
                    "hasExecutionEvidence": hasExecutionEvidence,
                    "toolExecutionContext": request.toolExecutionContext.rawValue,
                    "autoVerifySuggested": autoVerificationAssessment?.shouldAutoVerify as Any,
                    "autoVerifyConfidence": autoVerificationAssessment?.confidence as Any
                ]
            )
        }

        let phaseOutcome = AgentLoopPhaseOutcomeApplier.apply(
            phase: .finalizing,
            loopContext: &state.loopCtx,
            messages: &messages,
            accumulatedText: state.accumulatedText,
            accumulatedTextBeforeRound: outcome.accumulatedTextBeforeRound,
            currentRoundText: outcome.currentRoundText,
            assistantObjects: outcome.assistantObjects,
            reflectionEnabled: runtime.settings.enableReflection,
            verificationEnabled: verificationEnabled
        )

        if let projectedTextReset = phaseOutcome.projectedTextReset {
            state.accumulatedText = projectedTextReset
            await emitter.emit(
                .didReceiveTextDelta,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: ["length": state.accumulatedText.count],
                    projectedText: state.accumulatedText
                )
            )
        }
    }

    private func primaryUserTaskText(from messages: [MessageParameter.Message]) -> String {
        guard let taskMessage = messages.first(where: { $0.role == "user" }) else { return "" }
        return claudeService.extractText(from: taskMessage.content)
    }

    private func recordEpistemicInputEnvelope(
        sessionId: String,
        roundIndex: Int,
        messages: [MessageParameter.Message],
        currentRoundText: String? = nil,
        toolObservations: [String] = [],
        events: [AtomicEpistemicEvent] = []
    ) {
        let envelope = makeEpistemicInputEnvelope(
            sessionId: sessionId,
            roundIndex: roundIndex,
            messages: messages,
            currentRoundText: currentRoundText,
            toolObservations: toolObservations,
            events: events
        )
        var envelopes = sharedState.readEpistemicInputs(sessionId)
        envelopes.append(envelope)
        sharedState.writeEpistemicInputs(sessionId, envelopes)
    }

    private func makeEpistemicInputEnvelope(
        sessionId: String,
        roundIndex: Int,
        messages: [MessageParameter.Message],
        currentRoundText: String? = nil,
        toolObservations: [String],
        events: [AtomicEpistemicEvent]
    ) -> EpistemicInputEnvelope {
        var userAgentMessages = messages.compactMap { message -> String? in
            guard message.role == "user" || message.role == "assistant" else { return nil }
            let text = claudeService.extractText(from: message.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        if let currentRoundText {
            let trimmed = currentRoundText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                userAgentMessages.append(trimmed)
            }
        }

        let normalizedObservations = toolObservations.compactMap { observation -> String? in
            let trimmed = observation.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return EpistemicInputEnvelope(
            sessionID: sessionId,
            roundIndex: roundIndex,
            userAgentMessages: userAgentMessages,
            toolObservations: normalizedObservations,
            events: events
        )
    }
}