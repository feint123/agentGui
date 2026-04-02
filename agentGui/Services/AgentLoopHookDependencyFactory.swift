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
            extractMemoriesCallback: buildExtractionCallback()
        )
    }

    /// 构建 memory extraction 的执行闭包。
    /// 闭包捕获 coordinator（actor 隔离），在 detached Task 中通过 actor isolated 调用安全执行。
    private func buildExtractionCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let coordinator = MemoryExtractionCoordinator()
        let service = claudeService
        let settings = runtime.settings
        let sessionId = runtime.sessionId
        let modelContext = runtime.modelContext

        return { @Sendable context in
            // 守卫：已在运行中则跳过
            guard await coordinator.beginExtraction() else { return }
            defer { Task { await coordinator.finishExtraction() } }

            do {
                try await runMemoryExtraction(
                    context: context,
                    claudeService: service,
                    settings: settings,
                    sessionId: sessionId,
                    modelContext: modelContext
                )
            } catch {
                // 提取失败不影响主 loop，仅打印调试日志
                #if DEBUG
                print("[MemoryExtraction] error: \(error)")
                #endif
            }
        }
    }

    /// 实际运行 extraction subagent 的私有方法。
    /// 从 RMSInsightStore 读取现有 insights → 构建 prompt → 调用 runCoreAgentLoop
    private func runMemoryExtraction(
        context: AgentLoopHookContext,
        claudeService: ClaudeService,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws {
        // 1. 读取现有 insights（防重复写入）
        let existingInsights = (try? RMSInsightStore().load(scope: .user)) ?? []

        // 2. 计算本轮新消息数（context.messagesSnapshot 是本次 run 的完整消息列表）
        let messageCount = context.messagesSnapshot.count

        guard messageCount > 0 else { return }

        // 3. 构建提取 prompt
        let extractionPrompt = MemoryExtractionPromptBuilder.build(
            newMessageCount: messageCount,
            existingInsights: existingInsights
        )

        // 4. 构建受限工具集（仅 memory_write + read_file）
        let restrictedTools = await claudeService.buildExtractionTools(settings: settings)

        // 5. 启动 extraction subagent（最多 5 轮）
        var loopMessages: [MessageParameter.Message] = context.messagesSnapshot
        loopMessages.append(.init(role: .user, content: .text(extractionPrompt)))

        let extractionSystem = await claudeService.makeEphemeralSystemPrompt("")
        let extractionService = await claudeService.service

        guard let extractionService else { return }

        let request = AgentLoopRunRequest(
            service: extractionService,
            modelId: settings.selectedModel,
            tools: restrictedTools,
            system: extractionSystem,
            maxRounds: 5,
            toolExecutionContext: .backgroundTask,
            toolApprovalMode: .bypassApprovals,
            runSource: "memoryExtraction",
            runLabel: "Memory extraction",
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            remoteDeliveryHandle: nil
        )
        _ = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
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