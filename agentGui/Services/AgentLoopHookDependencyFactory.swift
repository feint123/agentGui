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
            // M-03
            extractMemoriesCallback: buildExtractionCallback(),
            // M-05
            memoryRecallService: buildMemoryRecallService(),
            // M-06
            consolidationCallback: buildConsolidationCallback()
        )
    }

    /// 构建 memory extraction 的执行闭包。
    /// 委托给 `SessionMemoryExtractorService` 处理，保持 factory 职责单一。
    private func buildExtractionCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        SessionMemoryExtractorService(
            claudeService: claudeService,
            settings: runtime.settings,
            sessionId: runtime.sessionId,
            modelContext: runtime.modelContext
        ).buildCallback()
    }

    /// 构建中段记忆召回服务（M-05）。
    /// 若 Anthropic service 尚未就绪（未配置 API Key）则返回 nil，hook 将直接跳过。
    private func buildMemoryRecallService() -> (any MemoryRecallServiceProtocol)? {
        guard let anthropicService = claudeService.service else { return nil }
        let sessionState = MemoryRecallSessionState()
        return RelevantMemoryRecallService(
            memoryDir: ConfigDirectoryManager.shared.memoryDir,
            sessionState: sessionState,
            service: anthropicService
        )
    }

    /// 构建记忆整合 callback（M-06）。
    ///
    /// 若 `memoryConsolidationEnabled` 为 false，callback 直接返回（guard 在 service 内部处理）。
    private func buildConsolidationCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        MemoryConsolidationService(
            claudeService: claudeService,
            settings: runtime.settings,
            sessionId: runtime.sessionId,
            modelContext: runtime.modelContext
        ).buildCallback()
    }

    private func loadMemoryBootstrap(
        state: AgentLoopBuiltInHookFactory.State
    ) async throws -> AgentLoopMessagePatch? {
        let taskStateStore = SessionTaskStateStore(modelContext: runtime.modelContext)
        let composer = AgentLoopMemoryBootstrapComposer(
            dependencies: .init(
                loadRMSState: {
                    taskStateStore.rmsState(for: runtime.sessionId)
                },
                loadInsights: { state in
                    try RMSInsightStore().load(
                        scopes: insightScopes(
                            for: state,
                            fallbackSessionID: runtime.sessionId
                        )
                    )
                }
            )
        )
        let composition = try await composer.compose(
            bootstrapMessageCount: bootstrapMessagesSnapshot.count,
            insightBudget: max(1, runtime.settings.memoryContextBudget / 4)
        )
        state.memoryRuntimeProfiles = []
        state.memoryRuntimeLayers = []
        state.memoryRuntimeWarnings = composition.runtimeWarnings
        state.memoryRuntimeSnapshotID = nil
        state.memoryRuntimeIntentPhase = nil
        state.memoryRuntimeWorkingSetCost = nil
        state.memoryRuntimeDereferenceCount = nil
        return composition.patch
    }

    private func insightScopes(for state: RMSState?, fallbackSessionID: String) -> [MemoryScope] {
        let workspaceRoot = [runtime.session?.workingDirectory, runtime.settings.workingDirectory]
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
        record.changeProposalID = context.metadata["changeProposalID"] as? UUID
        record.changeProposalStateRaw = context.metadata["changeProposalStateRaw"] as? String
        if let diffContent = context.metadata["changeProposalDiffContent"] as? String,
           !diffContent.isEmpty {
            record.diffContent = diffContent
        }
        if let payloadReadCount = context.metadata["toolPayloadReadCount"] as? Int {
            record.toolPayloadReadCount = payloadReadCount
        }
        if let status = context.metadata["toolStatus"] as? ToolStatus {
            record.status = status
        }
        record.endTime = Date()
        try? runtime.modelContext.save()
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