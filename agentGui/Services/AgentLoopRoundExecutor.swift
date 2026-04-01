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

    static func toolExecutionMetadata(
        toolName: String,
        input: MessageResponse.Content.Input,
        result: ToolExecutionResult,
        roundIndex: Int,
        claudeService: ClaudeService
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "toolName": toolName,
            "status": result.toolCallStatus.rawValue,
            "isError": result.isError,
            "outputLength": result.text.count,
            "roundIndex": roundIndex,
            "toolStatus": result.toolCallStatus,
            "toolResultSummary": result.envelope?.summary as Any,
            "toolResultPreview": result.envelope?.preview ?? result.rawOutputText ?? result.text,
            "toolPayloadRef": result.envelope?.payloadRef ?? input["payload_ref"]?.stringValue as Any,
            "toolResultRawChars": result.envelope?.rawCharCount ?? result.rawOutputText?.count ?? result.text.count,
            "toolResultInjectedChars": result.envelope?.injectedCharCount ?? result.text.count,
            "toolResultInjectionMode": result.envelope?.injectionMode.rawValue as Any,
            "toolPayloadLastReadRange": claudeService.payloadReadRangeSummary(from: input) as Any
        ]

        if toolName == "read_tool_payload" {
            metadata["toolPayloadReadCount"] = 1
        }

        if let changeProposalID = result.changeProposalID {
            metadata["changeProposalID"] = changeProposalID
        }
        if let changeProposalState = result.changeProposalState {
            metadata["changeProposalStateRaw"] = changeProposalState.rawValue
        }
        if let changeProposalDiffContent = result.changeProposalDiffContent,
           !changeProposalDiffContent.isEmpty {
            metadata["changeProposalDiffContent"] = changeProposalDiffContent
        }

        return metadata
    }

    func applyBootstrap(
        state: inout AgentLoopRunState,
        messages: inout [MessageParameter.Message]
    ) async throws {
        persistBootstrapRMSStateIfNeeded(messages: messages)

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
            let inputTokens = tokenCount.inputTokens
            sharedState.setCurrentInputTokens(inputTokens)

            // F-B1: 计算 context budget 级别并更新 session 上下文
            let budgetTracker = ContextWindowBudgetTracker()
            let windowSize = claudeService.contextWindowSize(for: modelId)
            let budgetState = budgetTracker.evaluate(tokenUsage: inputTokens, contextWindow: windowSize)
            sharedState.updateContextBudget(budgetState)

            // F-B1: Diminishing returns 检测 — 每次 countTokens 后记录
            let roundResult = state.budgetRunTracker.recordRound(currentGlobalTokens: inputTokens)
            if roundResult.isDiminishing {
                state.loopCtx.phase = .finalizing
                state.loopCtx.terminationReason = "diminishing_returns (continuation: \(roundResult.continuationCount), delta: \(roundResult.currentDeltaTokens))"
            }
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

        await recordEpistemicInputEnvelope(
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

        case .idle, .cancelled:
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

        // 使用批次规划器分批执行：连续的只读工具并发，其余工具串行
        let batchPlanner = ToolConcurrencyBatchPlanner(registry: DefaultToolRegistry())
        let batches = batchPlanner.partition(outcome.pendingTools)

        for batch in batches {
            switch batch {
            case .concurrent(let concurrentTools):
                try await executeConcurrentBatch(
                    tools: concurrentTools,
                    outcome: outcome,
                    state: &state,
                    messages: messages,
                    assistantObjects: &assistantObjects,
                    toolResultObjects: &toolResultObjects,
                    toolObservations: &toolObservations
                )
            case .serial(let serialTool):
                try await executeSerialTool(
                    tool: serialTool,
                    outcome: outcome,
                    state: &state,
                    messages: messages,
                    assistantObjects: &assistantObjects,
                    toolResultObjects: &toolResultObjects,
                    toolObservations: &toolObservations
                )
            }
        }

        messages.append(.init(role: .assistant, content: .list(assistantObjects)))
        messages.append(.init(role: .user, content: .list(toolResultObjects)))
        await recordEpistemicInputEnvelope(
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

        let effectiveVerificationState = state.verificationState
            ?? inMemoryVerification?.verificationState
            ?? storedVerification?.verificationState
        let verificationEnabled = Self.shouldEnableVerificationGate(
            toolExecutionContext: request.toolExecutionContext,
            accumulatedText: state.accumulatedText,
            verificationState: effectiveVerificationState,
            autoVerificationAssessment: autoVerificationAssessment
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

        let verificationResolution = Self.makeVerificationResolution(
            verificationState: effectiveVerificationState,
            verificationEnabled: verificationEnabled
        )

        let phaseOutcome = AgentLoopPhaseOutcomeApplier.apply(
            phase: .finalizing,
            loopContext: &state.loopCtx,
            messages: &messages,
            accumulatedText: state.accumulatedText,
            accumulatedTextBeforeRound: outcome.accumulatedTextBeforeRound,
            currentRoundText: outcome.currentRoundText,
            assistantObjects: outcome.assistantObjects,
            verificationEnabled: verificationEnabled,
            verificationResolution: verificationResolution
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

        if phaseOutcome.shouldResetVerificationState,
           let verificationState = effectiveVerificationState {
            let resetState = Self.resetVerificationStateForRepairLoop(verificationState)
            state.verificationState = resetState
            state.hookState.verificationState = resetState

            let store = SessionTaskStateStore(modelContext: runtime.modelContext)
            if var verification = inMemoryVerification ?? storedVerification {
                verification.passed = true
                verification.summary = "Repair loop reset verification gate"
                verification.missingEvidence = []
                verification.riskAreas = []
                verification.recommendedNextAction = nil
                verification.verificationState = resetState
                verification.recordedAt = Date()
                sharedState.writeVerification(runtime.sessionId, verification)
                try? store.saveVerification(verification, for: runtime.sessionId)
            }
        }
    }

    private func primaryUserTaskText(from messages: [MessageParameter.Message]) -> String {
        guard let taskMessage = messages.first(where: { $0.role == "user" }) else { return "" }
        return claudeService.extractText(from: taskMessage.content)
    }

    static func shouldEnableVerificationGate(
        toolExecutionContext: ToolContext,
        accumulatedText: String,
        verificationState: VerificationState?,
        autoVerificationAssessment: AutoVerificationAssessment?
    ) -> Bool {
        guard toolExecutionContext == .mainAgent,
              !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return verificationState != nil || ExecutionGuard.shouldAutoVerify(autoVerificationAssessment)
    }

    static func makeVerificationResolution(
        verificationState: VerificationState?,
        verificationEnabled: Bool
    ) -> VerificationGateResolution? {
        guard verificationEnabled else { return nil }

        guard let verificationState else {
            return .needsMoreEvidence(
                openClaims: ["Need direct runtime proof before finishing"],
                suggestedProbe: "Call run_subagent with verifier before finishing"
            )
        }

        if verificationState.certificate?.decision == .pass {
            return .clearToFinish
        }

        let openClaims = verificationState.certificate?.openClaims
        let resolvedOpenClaims = openClaims?.isEmpty == false
            ? openClaims ?? []
            : (verificationState.frontier.isEmpty
                ? ["Need direct runtime proof before finishing"]
                : verificationState.frontier.map(\.openQuestion))
        let suggestedProbe = verificationState.frontier.first?.recommendedProbe
            ?? "Call run_subagent with verifier before finishing"
        return .needsMoreEvidence(
            openClaims: resolvedOpenClaims,
            suggestedProbe: suggestedProbe
        )
    }

    static func resetVerificationStateForRepairLoop(_ verificationState: VerificationState) -> VerificationState {
        let certificate = ConvergenceCertificate(
            decision: .pass,
            supportedClaims: verificationState.certificate?.supportedClaims ?? [],
            contradictedClaims: [],
            openClaims: [],
            residualRisks: [],
            expectedValueOfMoreVerification: 0,
            stopReason: "Repair loop reset verification gate"
        )

        return VerificationState(
            riskScore: 0,
            claims: verificationState.claims,
            evidence: verificationState.evidence,
            frontier: [],
            repairQueue: [],
            openQuestions: [],
            certificate: certificate
        )
    }

    private func verifierMetadata(
        existing: [String: String]?,
        reduction: AgentLoopVerificationReduction
    ) -> [String: String] {
        var metadata = existing ?? [:]
        let certificate = reduction.verificationState.certificate
        metadata["verificationPassed"] = reduction.report.passed == true ? "true" : "false"
        metadata["verificationSummary"] = reduction.report.summary ?? certificate?.stopReason ?? ""
        metadata["verificationResidualRisk"] = String(format: "%.2f", reduction.verificationState.riskScore)
        metadata["verificationRecommendedProbe"] = reduction.verificationState.frontier.first?.recommendedProbe ?? ""
        metadata["verificationOpenClaimsCount"] = String(certificate?.openClaims.count ?? 0)
        metadata["verificationContradictedClaimsCount"] = String(certificate?.contradictedClaims.count ?? 0)
        return metadata
    }

    private func recordEpistemicInputEnvelope(
        sessionId: String,
        roundIndex: Int,
        messages: [MessageParameter.Message],
        currentRoundText: String? = nil,
        toolObservations: [String] = [],
        events: [AtomicEpistemicEvent] = []
    ) async {
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

        let store = SessionTaskStateStore(modelContext: runtime.modelContext)
        let existingState = store.rmsState(for: sessionId)

        let insightStore = RMSInsightStore()
        let generator = LLMRMSInsightGenerator(
            service: request.service,
            modelId: request.modelId
        )
        if let extraction = try? await RMSExtractor().extract(
            existing: existingState,
            envelope: envelope,
            generator: generator
        ) {
            if let nextState = RMSStateReducer().reduce(
                existing: existingState,
                delta: extraction.delta,
                sessionID: sessionId,
                threadID: sessionId,
                taskID: sessionId
            ) {
                try? store.saveRMSState(nextState, for: sessionId)
            }
            for proposal in extraction.proposals where proposal.insight.confidence >= 0.75 {
                try? insightStore.upsert(proposal.insight)
            }
        }
    }

    private func persistBootstrapRMSStateIfNeeded(messages: [MessageParameter.Message]) {
        let store = SessionTaskStateStore(modelContext: runtime.modelContext)
        if store.rmsState(for: runtime.sessionId) != nil {
            return
        }

        let summary = primaryUserTaskText(from: messages).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return
        }

        let bootstrapState = RMSState(
            taskID: runtime.sessionId,
            sessionID: runtime.sessionId,
            threadID: runtime.sessionId,
            summary: summary,
            updatedAt: Date()
        )
        try? store.saveRMSState(bootstrapState, for: runtime.sessionId)
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

    // MARK: - Tool Execution Helpers

    private func executeSerialTool(
        tool pending: AgentLoopPendingTool,
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: [MessageParameter.Message],
        assistantObjects: inout [MessageParameter.Message.Content.ContentObject],
        toolResultObjects: inout [MessageParameter.Message.Content.ContentObject],
        toolObservations: inout [String]
    ) async throws {
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
                metadata: Self.toolExecutionMetadata(
                    toolName: pending.name,
                    input: input,
                    result: result,
                    roundIndex: outcome.roundIndex,
                    claudeService: claudeService
                ),
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

        if pending.name == "run_subagent", record.subagentAgentName == "verifier" {
            let store = SessionTaskStateStore(modelContext: runtime.modelContext)
            let existingVerification = sharedState.readVerification(runtime.sessionId)
                ?? store.verification(for: runtime.sessionId)
            let reduction = AgentLoopVerificationCoordinator.reduceVerifierResult(
                rawText: result.text,
                existingVerification: existingVerification,
                executionEvidence: state.executionEvidence,
                verifierAgent: record.subagentAgentName ?? "verifier"
            )
            state.verificationState = reduction.verificationState
            state.hookState.verificationState = reduction.verificationState
            sharedState.writeVerification(runtime.sessionId, reduction.report)
            try? store.saveVerification(reduction.report, for: runtime.sessionId)
            state.loopCtx.pendingFailureTrigger = reduction.failureTrigger
            record.subagentMessageMetadata = verifierMetadata(
                existing: record.subagentMessageMetadata,
                reduction: reduction
            )
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

    private func executeConcurrentBatch(
        tools: [AgentLoopPendingTool],
        outcome: RoundOutcome,
        state: inout AgentLoopRunState,
        messages: [MessageParameter.Message],
        assistantObjects: inout [MessageParameter.Message.Content.ContentObject],
        toolResultObjects: inout [MessageParameter.Message.Content.ContentObject],
        toolObservations: inout [String]
    ) async throws {
        // Phase 1: Pre-hooks（串行）— 发出 willExecuteTool，创建 ToolCall 记录
        // 串行是因为 willExecuteTool 钩子会写入 ModelContext 并创建持久化记录
        struct PreHookEntry {
            let pending: AgentLoopPendingTool
            let record: ToolCall
        }
        var preHookEntries: [PreHookEntry] = []
        preHookEntries.reserveCapacity(tools.count)

        for pending in tools {
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

            let record = willExecuteHooks.toolCallRecord ?? claudeService.makeToolCallRecord(
                toolUseId: pending.id,
                toolName: pending.name,
                input: input,
                message: runtime.parentMessage,
                agentRound: outcome.round,
                executionContext: request.toolExecutionContext
            )
            assistantObjects.append(.toolUse(pending.id, pending.name, input))
            preHookEntries.append(PreHookEntry(pending: pending, record: record))
        }

        // Phase 2: 并发执行 — withTaskGroup 继承 @MainActor 隔离
        // 各任务的真正 I/O（网络、LSP）在 await 点让出 MainActor，允许其他任务同步推进
        // 使用预分配数组（index 寻址）避免收集结果时的 Sendable 约束
        var executionResults: [AgentLoopToolExecutionOutcome?] = Array(repeating: nil, count: tools.count)

        await withTaskGroup(of: Void.self) { group in
            for (index, entry) in preHookEntries.enumerated() {
                let pending = entry.pending
                let record = entry.record
                group.addTask { @MainActor in
                    let ex = await self.toolCoordinator.execute(
                        pendingTool: pending,
                        record: record,
                        interceptor: self.runtime.toolInterceptor
                    )
                    executionResults[index] = ex
                }
            }
        }

        // Phase 3: 后处理（串行，按原始顺序）
        // executionResults 此时已全部填充；按 preHookEntries 顺序处理确保 toolResultObjects 顺序正确
        for (index, entry) in preHookEntries.enumerated() {
            guard let executionOutcome = executionResults[index] else { continue }
            let pending = entry.pending
            let record = entry.record
            let result = executionOutcome.result
            let input = pending.parsedInput

            let toolSpan = PerformanceMonitor.self.startSpan("tool_\(pending.name)", category: "Tool", level: .normal)

            if let evidence = ExecutionGuard.evidenceKind(toolName: pending.name, input: input, result: result) {
                state.executionEvidence.insert(evidence)
                sharedState.writeExecutionEvidence(runtime.sessionId, state.executionEvidence)
            }

            await emitter.emit(
                .didExecuteTool,
                state: state,
                messages: messages,
                overrides: .init(
                    metadata: Self.toolExecutionMetadata(
                        toolName: pending.name,
                        input: input,
                        result: result,
                        roundIndex: outcome.roundIndex,
                        claudeService: claudeService
                    ),
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

            // run_subagent 的 isConcurrencySafe = false，此分支实践中不会触发；保留以备安全
            if pending.name == "run_subagent", record.subagentAgentName == "verifier" {
                let store = SessionTaskStateStore(modelContext: runtime.modelContext)
                let existingVerification = sharedState.readVerification(runtime.sessionId)
                    ?? store.verification(for: runtime.sessionId)
                let reduction = AgentLoopVerificationCoordinator.reduceVerifierResult(
                    rawText: result.text,
                    existingVerification: existingVerification,
                    executionEvidence: state.executionEvidence,
                    verifierAgent: record.subagentAgentName ?? "verifier"
                )
                state.verificationState = reduction.verificationState
                state.hookState.verificationState = reduction.verificationState
                sharedState.writeVerification(runtime.sessionId, reduction.report)
                try? store.saveVerification(reduction.report, for: runtime.sessionId)
                state.loopCtx.pendingFailureTrigger = reduction.failureTrigger
                record.subagentMessageMetadata = verifierMetadata(
                    existing: record.subagentMessageMetadata,
                    reduction: reduction
                )
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
    }
}