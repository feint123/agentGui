import Foundation
import SwiftAnthropic
import SwiftData

@MainActor
/// 组装内建 hook 依赖。
/// 它把原来散落在 runCoreAgentLoop 里的大块闭包提炼成命名方法，便于测试和后续替换。
struct AgentLoopHookDependencyFactory {
    let claudeService: ClaudeService
    let request: AgentLoopRunRequest
    let runtime: AgentLoopRuntime
    let bootstrapMessagesSnapshot: [MessageParameter.Message]

    func build(state: AgentLoopBuiltInHookFactory.State) -> AgentLoopBuiltInHookFactory.Dependencies {
        AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: claudeService.businessLogSink,
            memoryBootstrapLoader: { hookState in
                try await loadMemoryBootstrap(state: hookState)
            },
            createToolCallRecord: { context, hookState in
                try await createToolCallRecord(context: context, state: hookState)
            },
            updateToolCallRecord: { context, hookState in
                try await updateToolCallRecord(context: context, state: hookState)
            },
            reflectionResolver: { context, hookState in
                try await resolveReflection(context: context, state: hookState)
            }
        )
    }

    private func loadMemoryBootstrap(
        state: AgentLoopBuiltInHookFactory.State
    ) async throws -> AgentLoopMessagePatch? {
        // bootstrap 既返回 message patch，也把 runtime snapshot 写回共享 hook state，供 tool audit 等后续 hook 读取。
        let unifiedStore = UnifiedMemoryFileStoreAdapter()
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadUnifiedContext: {
                    try await claudeService.buildUnifiedMemoryBootstrap(
                        settings: runtime.settings,
                        session: runtime.session,
                        sessionId: runtime.sessionId,
                        messages: bootstrapMessagesSnapshot,
                        modelContext: runtime.modelContext
                    )
                },
                loadTaskMemory: {
                    guard !runtime.sessionId.isEmpty else { return nil }
                    return try claudeService.loadTaskMemory(sessionId: runtime.sessionId, store: unifiedStore)
                },
                loadTaskMemoryPromptText: {
                    guard !runtime.sessionId.isEmpty else { return nil }
                    return try claudeService.taskMemoryPromptText(sessionId: runtime.sessionId, store: unifiedStore)
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
        state.memoryRuntimeIntentPhase = composition.runtimeIntentPhase
        state.memoryRuntimeWorkingSetCost = composition.runtimeWorkingSetCost
        state.memoryRuntimeBridgeExpansionCount = composition.runtimeBridgeExpansionCount
        state.memoryRuntimeDereferenceCount = composition.runtimeDereferenceCount
        return composition.patch
    }

    private func createToolCallRecord(
        context: AgentLoopHookContext,
        state: AgentLoopBuiltInHookFactory.State
    ) async throws -> ToolCall {
        // ToolCall 记录创建时就要捕获 memory runtime 元数据，避免后续阶段拿到的是漂移后的状态。
        let record = claudeService.makeToolCallRecord(
            toolUseId: pendingToolID(from: context),
            toolName: context.pendingToolName ?? "unknown",
            input: context.toolInput,
            message: runtime.parentMessage,
            agentRound: roundForToolContext(from: context, fallback: state.lastRound),
            executionContext: request.toolExecutionContext
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
        if let memoryRuntimeIntentPhase = state.memoryRuntimeIntentPhase,
           !memoryRuntimeIntentPhase.isEmpty {
            record.memoryRuntimeIntentPhase = memoryRuntimeIntentPhase
        }
        if let memoryRuntimeWorkingSetCost = state.memoryRuntimeWorkingSetCost {
            record.memoryRuntimeWorkingSetCost = memoryRuntimeWorkingSetCost
        }
        if let memoryRuntimeBridgeExpansionCount = state.memoryRuntimeBridgeExpansionCount {
            record.memoryRuntimeBridgeExpansionCount = memoryRuntimeBridgeExpansionCount
        }
        if let memoryRuntimeDereferenceCount = state.memoryRuntimeDereferenceCount {
            record.memoryRuntimeDereferenceCount = memoryRuntimeDereferenceCount
        }
        runtime.modelContext.insert(record)
        try? runtime.modelContext.save()
        return record
    }

    private func updateToolCallRecord(
        context: AgentLoopHookContext,
        state _: AgentLoopBuiltInHookFactory.State
    ) async throws {
        guard let record = context.toolCallRecord else { return }
        // UI 优先展示经过 budget shaping 的 preview；若没有 preview 再回落到完整文本。
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
        try? runtime.modelContext.save()
    }

    private func resolveReflection(
        context: AgentLoopHookContext,
        state: AgentLoopBuiltInHookFactory.State
    ) async throws -> AgentLoopReflectionResolution? {
        // reflection 本身是 host-side 阶段，但它仍需要把分析结果写回 round 和 failure audit，保持历史可追溯。
        let reflection = await claudeService.reflectOnRound(
            messages: context.messagesSnapshot,
            service: request.service,
            modelId: request.modelId,
            settings: runtime.settings,
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
            try? runtime.modelContext.save()
        }

        if (!reflection.concerns.isEmpty || !reflection.suggestedFixes.isEmpty), !runtime.sessionId.isEmpty {
            try? claudeService.recordReflectionFailure(
                sessionId: runtime.sessionId,
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

    private func pendingToolID(from context: AgentLoopHookContext) -> String {
        (context.metadata["toolUseID"] as? String) ?? UUID().uuidString
    }

    private func roundForToolContext(
        from context: AgentLoopHookContext,
        fallback: AgentRound?
    ) -> AgentRound? {
        // tool hook 可以显式指定 round；否则退回到 hook state 中记录的最后一轮。
        (context.metadata["agentRound"] as? AgentRound) ?? fallback
    }
}