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
            memoryRecallService: buildMemoryRecallService()
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

    private func loadMemoryBootstrap(
        state _: AgentLoopBuiltInHookFactory.State
    ) async throws -> String? {
        guard runtime.settings.memoryEnabled else { return nil }
        let composer = AgentLoopMemoryBootstrapComposer(
            memoryDir: ConfigDirectoryManager.shared.memoryDir
        )
        return composer.compose().systemPromptSection
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